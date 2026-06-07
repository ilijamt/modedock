import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import PrivateAPI

public struct BatteryStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case onBattery, charging, charged
        /// Plugged in but not charging, for example with Optimized Battery Charging.
        case notCharging
    }

    public var percent: Int
    public var state: State
    /// Until empty on battery, until full while charging; nil while macOS is still estimating.
    public var minutesRemaining: Int?

    public init(percent: Int, state: State, minutesRemaining: Int? = nil) {
        self.percent = percent
        self.state = state
        self.minutesRemaining = minutesRemaining
    }

    /// Reads one entry of `IOPSGetPowerSourceDescription`. Returns nil for anything but the
    /// internal battery (UPSs and accessories also show up there).
    public init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
            description[kIOPSIsPresentKey] as? Bool ?? true,
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
        else { return nil }
        percent = min(100, current * 100 / maximum)

        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let charged = description[kIOPSIsChargedKey] as? Bool ?? false
        let minutes: Int?
        switch (onAC, charging) {
        case (false, _):
            state = .onBattery
            minutes = description[kIOPSTimeToEmptyKey] as? Int
        case (true, true):
            state = .charging
            minutes = description[kIOPSTimeToFullChargeKey] as? Int
        default:
            state = charged || percent >= 100 ? .charged : .notCharging
            minutes = nil
        }
        // -1 means macOS is still calculating.
        minutesRemaining = minutes.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Power management calls, abstracted for tests.
@MainActor
public protocol PowerSystem {
    /// Returns an assertion id, or nil when macOS refused it.
    func preventSleep(keepScreensOn: Bool, reason: String) -> UInt32?
    func allowSleep(_ assertion: UInt32)
    func sleep() throws
    func lockScreen() throws
    func battery() -> BatteryStatus?
}

@MainActor
public struct IOKitPowerSystem: PowerSystem {
    public init() {}

    public func preventSleep(keepScreensOn: Bool, reason: String) -> UInt32? {
        let type = keepScreensOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    public func allowSleep(_ assertion: UInt32) {
        IOPMAssertionRelease(assertion)
    }

    public func sleep() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PowerError.commandFailed }
    }

    public func lockScreen() throws {
        guard let lock = PrivateAPI.lockScreen else { throw PowerError.unsupported }
        guard lock() == 0 else { throw PowerError.commandFailed }
    }

    public func battery() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any],
                let status = BatteryStatus(description: description)
            {
                return status
            }
        }
        return nil
    }
}

public enum PowerError: Error, LocalizedError {
    case unsupported, commandFailed, assertionRefused

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This isn't supported on this version of macOS."
        case .commandFailed: "macOS didn't carry out the request."
        case .assertionRefused: "macOS refused to keep the Mac awake."
        }
    }
}

@MainActor
@Observable
public final class PowerController {
    /// How long Keep Awake lasts. `nil` minutes means until it's turned off.
    public enum Duration: Int, CaseIterable, Identifiable, Sendable {
        case indefinitely = 0
        case minutes15 = 15, minutes30 = 30, hour1 = 60, hours2 = 120, hours4 = 240, hours8 = 480

        public var id: Int { rawValue }
        public var minutes: Int? { self == .indefinitely ? nil : rawValue }

        public var title: String {
            switch self {
            case .indefinitely: "Until turned off"
            case .minutes15: "15 minutes"
            case .minutes30: "30 minutes"
            case .hour1: "1 hour"
            case .hours2: "2 hours"
            case .hours4: "4 hours"
            case .hours8: "8 hours"
            }
        }
    }

    public struct KeepAwake: Equatable, Sendable {
        public var duration: Duration
        /// nil when it lasts until turned off.
        public var endsAt: Date?
    }

    public private(set) var keepAwake: KeepAwake?
    public private(set) var battery: BatteryStatus?
    public private(set) var lastError: String?

    private let system: PowerSystem
    private var assertion: UInt32?
    private var expiry: Task<Void, Never>?

    public init(system: PowerSystem = IOKitPowerSystem()) {
        self.system = system
    }

    public var isKeepingAwake: Bool { keepAwake != nil }

    /// Starts Keep Awake, replacing one that's already running.
    public func startKeepAwake(_ duration: Duration, keepScreensOn: Bool) {
        stopKeepAwake()
        guard let id = system.preventSleep(keepScreensOn: keepScreensOn, reason: "Keep Awake in ModeDock") else {
            report(PowerError.assertionRefused)
            return
        }
        assertion = id
        lastError = nil
        let endsAt = duration.minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        keepAwake = KeepAwake(duration: duration, endsAt: endsAt)
        if let minutes = duration.minutes {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                self?.stopKeepAwake()
            }
        }
    }

    /// Switches between keeping the screens on and letting them sleep, without restarting the timer.
    public func setKeepScreensOn(_ keepScreensOn: Bool) {
        guard let old = assertion else { return }
        guard let id = system.preventSleep(keepScreensOn: keepScreensOn, reason: "Keep Awake in ModeDock") else {
            report(PowerError.assertionRefused)
            return
        }
        // The new assertion is in place before the old one goes, so there's no gap to fall asleep in.
        assertion = id
        system.allowSleep(old)
    }

    public func stopKeepAwake() {
        expiry?.cancel()
        expiry = nil
        if let assertion { system.allowSleep(assertion) }
        assertion = nil
        keepAwake = nil
    }

    /// Keep Awake only holds off idle sleep, so it doesn't block this.
    public func sleep() {
        do {
            try system.sleep()
            lastError = nil
        } catch {
            report(error)
        }
    }

    public func lockScreen() {
        do {
            try system.lockScreen()
            lastError = nil
        } catch {
            report(error)
        }
    }

    public func refreshBattery() {
        battery = system.battery()
    }

    private func report(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
