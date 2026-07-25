import DisplayKit
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
        guard try PMSet.run("sleepnow") else { throw PowerError.commandFailed }
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
        case .unsupported: String(localized: "This isn't supported on this version of macOS.", bundle: .module)
        case .commandFailed: String(localized: "macOS didn't carry out the request.", bundle: .module)
        case .assertionRefused: String(localized: "macOS refused to keep the Mac awake.", bundle: .module)
        }
    }
}

@MainActor
@Observable
public final class PowerController {
    /// The durations offered in menus, in minutes; nil is "until turned off".
    public static let presets: [Int?] = [nil, 15, 30, 60, 120, 240, 480]

    /// String(localized: "Until turned off", bundle: .module), "15 minutes", "2 hours", "1 h 30 min".
    public static func title(minutes: Int?) -> String {
        guard let minutes else { return String(localized: "Until turned off", bundle: .module) }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        switch (hours, rest) {
        case (0, _): return String(localized: "\(rest) minutes", bundle: .module)
        case (_, 0): return String(localized: "\(hours) hours", bundle: .module)
        default: return String(localized: "\(hours) h \(rest) min", bundle: .module)
        }
    }

    /// Reads a typed duration: "90" (minutes), "45m", "2h", "1h30", "1h 30m", "1:30" or "1.5h".
    /// Returns nil for anything else, for zero, and for more than a week.
    public static func minutes(from text: String) -> Int? {
        let text = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        let total: Double?
        if let match = text.wholeMatch(of: /(\d+):(\d{1,2})/) {
            total = Double(match.1).flatMap { hours in Double(match.2).map { hours * 60 + $0 } }
        } else if let match = text.wholeMatch(
            of: /(?:(\d+(?:[.,]\d+)?)h(?:ours?|rs?)?)?(?:(\d+)m(?:in(?:utes?|s)?)?)?/),
            match.1 != nil || match.2 != nil
        {
            let hours = match.1.flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) } ?? 0
            let minutes = match.2.flatMap { Double($0) } ?? 0
            total = hours * 60 + minutes
        } else if let match = text.wholeMatch(of: /(\d+)h(\d+)/) {
            total = Double(match.1).flatMap { hours in Double(match.2).map { hours * 60 + $0 } }
        } else {
            total = Double(text)
        }
        guard let total, total >= 1, total <= 7 * 24 * 60 else { return nil }
        return Int(total.rounded())
    }

    /// Minutes from `now` until the next `time` of day; tomorrow when it has already passed today.
    public static func minutes(until time: Date, from now: Date = Date(), calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        let next =
            calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(24 * 3600)
        return max(1, Int((next.timeIntervalSince(now) / 60).rounded(.up)))
    }

    public struct KeepAwake: Equatable, Sendable {
        /// nil when it lasts until turned off.
        public var minutes: Int?
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
    /// `minutes` nil keeps the Mac awake until turned off.
    public func startKeepAwake(minutes: Int?, keepScreensOn: Bool) {
        stopKeepAwake()
        guard let id = preventSleep(keepScreensOn: keepScreensOn) else { return }
        assertion = id
        lastError = nil
        let minutes = minutes.flatMap { $0 > 0 ? $0 : nil }
        let endsAt = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        keepAwake = KeepAwake(minutes: minutes, endsAt: endsAt)
        if let minutes {
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
        guard let id = preventSleep(keepScreensOn: keepScreensOn) else { return }
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
        lastError = errorMessage { try system.sleep() }
    }

    public func lockScreen() {
        lastError = errorMessage { try system.lockScreen() }
    }

    public func refreshBattery() {
        battery = system.battery()
    }

    private func preventSleep(keepScreensOn: Bool) -> UInt32? {
        let id = system.preventSleep(keepScreensOn: keepScreensOn, reason: "Keep Awake in ModeDock")
        if id == nil { lastError = PowerError.assertionRefused.localizedDescription }
        return id
    }
}
