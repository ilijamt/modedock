import CoreGraphics
import DisplayKit
import Foundation
import Observation

@MainActor
@Observable
public final class BrightnessController {
    public struct ScreenBrightness: Equatable, Sendable {
        public var value: Double
        public var backend: BrightnessBackend
        public var autoBrightness: Bool? = nil

        public var minimum: Double { backend == .software ? BrightnessController.softwareMinimum : 0 }
    }

    /// Dimming never reaches black, so the screen stays usable.
    public nonisolated static let softwareMinimum = 0.15

    public private(set) var screens: [CGDirectDisplayID: ScreenBrightness] = [:]
    public private(set) var lastError: String? {
        // Only the error kind is counted, never its text.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorBrightness) } }
    }

    private let system: BrightnessSystem
    private let ddc: DDCControlling
    /// Longer reduces flicker on monitors that fade their backlight with every change, but the
    /// monitor follows the slider less closely.
    public var ddcWriteInterval: Duration
    private var identities: [CGDirectDisplayID: DisplayIdentity] = [:]
    private var pendingDDC: [CGDirectDisplayID: Double] = [:]
    private var ddcWriters: Set<CGDirectDisplayID> = []
    /// Bumped on every user change, so a refresh that was reading in the meantime
    /// doesn't overwrite the slider with an older value.
    private var changes: [CGDirectDisplayID: Int] = [:]

    public init(
        system: BrightnessSystem = CoreBrightnessSystem(),
        ddc: DDCControlling,
        ddcWriteInterval: Duration = .milliseconds(50)
    ) {
        self.system = system
        self.ddc = ddc
        self.ddcWriteInterval = ddcWriteInterval
    }

    public func refresh(displays: [Display]) async {
        let enabled = displays.filter(\.isEnabled)
        let changesAtStart = changes
        identities = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0.identity) })
        var updated: [CGDirectDisplayID: ScreenBrightness] = [:]

        for display in enabled {
            if system.canControl(display.id) {
                let value = system.brightness(of: display.id) ?? screens[display.id]?.value ?? 1
                updated[display.id] = ScreenBrightness(
                    value: value, backend: .system, autoBrightness: system.autoBrightness(of: display.id))
            } else if pendingDDC[display.id] != nil || ddcWriters.contains(display.id),
                let current = screens[display.id]
            {
                // Mid-drag: the monitor hasn't caught up yet, so keep the slider's value.
                updated[display.id] = current
            } else if !display.isBuiltin,
                let reply = try? await ddc.read(DDCPacket.VCP.brightness, from: display.identity),
                reply.maximum > 0
            {
                updated[display.id] = ScreenBrightness(
                    value: Double(reply.current) / Double(reply.maximum), backend: .ddc(maximum: reply.maximum))
            } else {
                let value = screens[display.id]?.backend == .software ? screens[display.id]?.value ?? 1 : 1
                updated[display.id] = ScreenBrightness(value: value, backend: .software)
                // macOS resets gamma tables when displays change, so dimming is applied again.
                if value < 1 { system.setSoftwareDimming(value, of: display.id) }
            }
        }
        for (id, count) in changes where changesAtStart[id] != count {
            updated[id] = screens[id] ?? updated[id]
        }
        screens = updated
    }

    /// Cheap enough to call every second while the panel is open.
    public func syncSystemBrightness() {
        for (id, screen) in screens where screen.backend == .system {
            var synced = screen
            if let value = system.brightness(of: id) { synced.value = value }
            synced.autoBrightness = system.autoBrightness(of: id)
            if synced != screen { screens[id] = synced }
        }
    }

    /// Returns this change's error. DDC writes happen later and report theirs in `lastError`.
    @discardableResult
    public func set(_ value: Double, for display: CGDirectDisplayID) -> String? {
        guard var screen = screens[display] else { return nil }
        screen.value = min(max(value, screen.minimum), 1)
        screens[display] = screen
        changes[display, default: 0] += 1

        switch screen.backend {
        case .system:
            lastError = errorMessage { try system.setBrightness(screen.value, of: display) }
            return lastError
        case .ddc(let maximum):
            pendingDDC[display] = screen.value
            startDDCWriter(for: display, maximum: maximum)
        case .software:
            system.setSoftwareDimming(screen.value, of: display)
        }
        return nil
    }

    public func setAutoBrightness(_ enabled: Bool, for display: CGDirectDisplayID) {
        guard screens[display]?.autoBrightness != nil else { return }
        lastError = errorMessage {
            try system.setAutoBrightness(enabled, of: display)
            screens[display]?.autoBrightness = system.autoBrightness(of: display)
        }
    }

    /// DDC and built-in levels have no factory value to go back to, so they're left alone.
    public func resetToDefault(for display: CGDirectDisplayID) {
        guard let screen = screens[display] else { return }
        if screen.backend == .software { set(1, for: display) }
        if screen.autoBrightness == false { setAutoBrightness(true, for: display) }
    }

    public func resetSoftwareDimming() {
        system.resetSoftwareDimming()
        for (id, screen) in screens where screen.backend == .software {
            screens[id]?.value = 1
        }
    }

    /// Each value goes out once while dragging, which keeps the steps the monitor fades through to a
    /// minimum; once the slider stops, the final value is sent again in case the monitor missed it.
    private func startDDCWriter(for display: CGDirectDisplayID, maximum: UInt16) {
        guard !ddcWriters.contains(display), let identity = identities[display] else { return }
        ddcWriters.insert(display)
        Task { [weak self] in
            var unconfirmed: UInt16?
            while let self {
                let raw: UInt16
                if let value = self.pendingDDC.removeValue(forKey: display) {
                    raw = UInt16((value * Double(maximum)).rounded())
                    unconfirmed = raw
                } else if let last = unconfirmed {
                    raw = last
                    unconfirmed = nil
                } else {
                    break
                }
                self.lastError = await errorMessage {
                    try await self.ddc.write(DDCPacket.VCP.brightness, value: raw, to: identity, attempts: 1)
                }
                try? await Task.sleep(for: self.ddcWriteInterval)
            }
            self?.ddcWriters.remove(display)
        }
    }
}
