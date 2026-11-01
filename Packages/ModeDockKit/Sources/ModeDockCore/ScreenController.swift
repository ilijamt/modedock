import CoreGraphics
import DisplayKit
import Foundation
import Observation
import os

private let log = AppLog.screens

@MainActor
@Observable
public final class ScreenController {
    public struct Screen: Identifiable, Equatable, Sendable {
        public var display: Display
        public var supportsDDC: Bool
        /// Set by ModeDock; a monitor can also be woken with its own power button.
        public var isInStandby: Bool
        public var canDisable: Bool

        public var id: CGDirectDisplayID { display.id }
    }

    public private(set) var screens: [Screen] = []
    public private(set) var lastError: String? {
        // Counted by kind only, when a new error appears.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorScreen) } }
    }

    private let system: DisplaySystem
    private let ddc: DDCControlling
    private let defaults: UserDefaults
    private static let disabledKey = "disabledDisplayIDs"

    /// Displays ModeDock disabled. Persisted so a crash doesn't leave a screen off.
    private var disabled: Set<CGDirectDisplayID> {
        didSet { defaults.set(disabled.map { Int($0) }, forKey: Self.disabledKey) }
    }
    private var known: [CGDirectDisplayID: Display] = [:]
    private var ddcCapable: Set<DisplayIdentity> = []
    private var standby: Set<DisplayIdentity> = []

    public init(
        system: DisplaySystem = CoreGraphicsDisplaySystem(),
        ddc: DDCControlling = makeDDCService(),
        defaults: UserDefaults = .standard
    ) {
        self.system = system
        self.ddc = ddc
        self.defaults = defaults
        let saved = defaults.array(forKey: Self.disabledKey) as? [Int] ?? []
        self.disabled = Set(saved.map { CGDirectDisplayID($0) })
    }

    /// Re-enables displays left off by a previous run, then loads the current state.
    public func start() async {
        for id in disabled {
            try? system.setEnabled(true, display: id)
        }
        disabled = []
        await displaysChanged()
    }

    public func displaysChanged() async {
        // Unplugging the only screen that's on would leave nothing visible. Sleeping screens are
        // inactive too, so only count a screen as unusable when ModeDock turned it off. The
        // placeholder macOS adds when nothing is connected doesn't count as a screen.
        let online = system.onlineDisplays()
        log.info(
            "displays changed: online=\(online.map { "\($0.id):\($0.isEnabled):vendor=\($0.identity.vendor)" }) disabled=\(self.disabled.sorted())"
        )
        let usable = online.contains { !$0.identity.isPlaceholder && ($0.isEnabled || !disabled.contains($0.id)) }
        if !disabled.isEmpty && !usable {
            restoreDisabled()
        }
        refresh()
        await ddc.refresh()
        var capable: Set<DisplayIdentity> = []
        for screen in screens where !screen.display.isBuiltin {
            if (try? await ddc.read(DDCPacket.VCP.powerMode, from: screen.display.identity)) != nil {
                capable.insert(screen.display.identity)
            }
        }
        ddcCapable = capable
        refresh()
    }

    public func setEnabled(_ enabled: Bool, screen id: CGDirectDisplayID) {
        let enabledIDs = Set(screens.filter(\.display.isEnabled).map(\.id))
        if !enabled && !DisplayPolicy.canDisable(id, enabled: enabledIDs) {
            lastError = DisplayError.wouldDisableLastDisplay.localizedDescription
            return
        }
        lastError = errorMessage {
            try system.setEnabled(enabled, display: id)
            if enabled { disabled.remove(id) } else { disabled.insert(id) }
        }
        refresh()
    }

    public func setStandby(_ on: Bool, screen id: CGDirectDisplayID) async {
        Telemetry.shared.record(.screenStandby)
        guard let identity = screens.first(where: { $0.id == id })?.display.identity else { return }
        lastError = await errorMessage {
            let mode = on ? DDCPacket.PowerMode.off : DDCPacket.PowerMode.on
            try await ddc.write(DDCPacket.VCP.powerMode, value: mode, to: identity)
            if on { standby.insert(identity) } else { standby.remove(identity) }
        }
        refresh()
    }

    public func sleepAllDisplays() {
        Telemetry.shared.record(.screensSlept)
        lastError = errorMessage { try system.sleepAllDisplays() }
    }

    /// Turns every display back on: the ones ModeDock disabled and the ones it put in standby.
    public func restoreAll() async {
        restoreDisabled()
        for identity in standby {
            try? await ddc.write(DDCPacket.VCP.powerMode, value: DDCPacket.PowerMode.on, to: identity)
        }
        standby = []
        refresh()
    }

    /// Synchronous part of `restoreAll`, safe to call while the app terminates.
    public func restoreDisabled() {
        for id in disabled {
            do {
                try system.setEnabled(true, display: id)
                disabled.remove(id)
                log.info("re-enabled display \(id)")
            } catch {
                log.error("re-enabling display \(id) failed: \(error)")
                lastError = error.localizedDescription
            }
        }
    }

    private func refresh() {
        let online = system.onlineDisplays()
        for display in online { known[display.id] = display }
        // A disabled display can drop out of the online list; keep showing it so it can be enabled.
        var displays = online
        for id in disabled where !online.contains(where: { $0.id == id }) {
            if var display = known[id] {
                display.isEnabled = false
                displays.append(display)
            }
        }
        // Reconnecting a disabled display brings it back enabled; stop tracking it.
        for display in online where display.isEnabled { disabled.remove(display.id) }

        let enabledIDs = Set(displays.filter(\.isEnabled).map(\.id))
        screens =
            displays
            .sorted { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
            .map { display in
                Screen(
                    display: display,
                    supportsDDC: ddcCapable.contains(display.identity),
                    isInStandby: standby.contains(display.identity),
                    canDisable: DisplayPolicy.canDisable(display.id, enabled: enabledIDs)
                )
            }
    }
}
