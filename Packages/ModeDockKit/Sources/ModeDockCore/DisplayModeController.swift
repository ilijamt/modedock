import CoreGraphics
import DisplayKit
import Foundation
import Observation

@MainActor
@Observable
public final class DisplayModeController {
    public struct ScreenModes: Equatable, Sendable {
        public var options: [ResolutionOption]
        public var current: DisplayMode?
        public var isMain: Bool
        public var defaultMode: DisplayMode? = nil

        public var isAtDefault: Bool { defaultMode == nil || defaultMode?.id == current?.id }
    }

    public struct PendingChange: Equatable, Sendable {
        public let display: CGDirectDisplayID
        public let previous: DisplayMode
        public let new: DisplayMode
        public let deadline: Date
    }

    public private(set) var screens: [CGDirectDisplayID: ScreenModes] = [:]
    public private(set) var pending: PendingChange?
    public private(set) var isMirroring = false
    public private(set) var lastError: String? {
        // Only the error kind is counted, never its text.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorResolution) } }
    }
    public var onConfirmationNeeded: ((PendingChange) -> Void)?

    private let configurator: DisplayConfiguring
    private let defaults: UserDefaults
    private let confirmationTimeout: Duration
    private var displays: [Display] = []
    private var showAllModes = false
    private var revertTask: Task<Void, Never>?
    private static let confirmedKey = "confirmedDisplayModes"

    public init(
        configurator: DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
        defaults: UserDefaults = .standard,
        confirmationTimeout: Duration = .seconds(15)
    ) {
        self.configurator = configurator
        self.defaults = defaults
        self.confirmationTimeout = confirmationTimeout
    }

    public var canMirror: Bool { displays.count > 1 }

    public func refresh(displays: [Display], showAllModes: Bool) {
        self.displays = displays.filter(\.isEnabled)
        self.showAllModes = showAllModes
        reload()
    }

    public func refresh(displays: [Display]) {
        refresh(displays: displays, showAllModes: showAllModes)
    }

    /// For modes known to work, such as the ones saved in a profile.
    public func applyKnownMode(key: String, for display: CGDirectDisplayID) throws {
        if configurator.currentMode(for: display)?.key == key { return }
        // Several modes can share a key (different pixel encodings); prefer the native, then the largest.
        guard
            let mode = configurator.modes(for: display, includeDuplicates: true)
                .filter({ $0.key == key })
                .max(by: { ($0.isNative ? 1 : 0, $0.pixelWidth) < ($1.isNative ? 1 : 0, $1.pixelWidth) })
        else { throw DisplayError.modeUnavailable }
        if pending?.display == display {
            revertTask?.cancel()
            pending = nil
        }
        try configurator.setMode(mode, for: display)
        if let identity = identity(of: display) { markConfirmed(mode, on: identity) }
        reload()
    }

    public func select(_ mode: DisplayMode, for display: CGDirectDisplayID) {
        guard pending == nil, let identity = identity(of: display) else { return }
        Telemetry.shared.record(.screenResolution)
        let previous = configurator.currentMode(for: display)
        guard previous?.id != mode.id else { return }
        // The mode the user is leaving works, so switching back to it never needs a prompt.
        if let previous { markConfirmed(previous, on: identity) }
        lastError = errorMessage { try configurator.setMode(mode, for: display) }
        guard lastError == nil else { return }
        reload()

        guard let previous, !isConfirmed(mode, on: identity) else { return }
        let change = PendingChange(
            display: display, previous: previous, new: mode,
            deadline: Date().addingTimeInterval(confirmationTimeout / .seconds(1)))
        pending = change
        onConfirmationNeeded?(change)
        revertTask = Task { [weak self, confirmationTimeout] in
            try? await Task.sleep(for: confirmationTimeout)
            guard !Task.isCancelled, self?.pending == change else { return }
            self?.revert()
        }
    }

    public func confirm() {
        if pending != nil { Telemetry.shared.record(.resolutionKeep) }
        guard let change = pending else { return }
        revertTask?.cancel()
        if let identity = identity(of: change.display) { markConfirmed(change.new, on: identity) }
        pending = nil
    }

    public func revert() {
        if pending != nil { Telemetry.shared.record(.resolutionRevert) }
        guard let change = pending else { return }
        revertTask?.cancel()
        pending = nil
        do {
            try configurator.setMode(change.previous, for: change.display)
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    /// It's the mode macOS itself picks, so it doesn't ask for confirmation.
    public func resetToDefault(_ display: CGDirectDisplayID) {
        guard let mode = screens[display]?.defaultMode, let identity = identity(of: display) else { return }
        markConfirmed(mode, on: identity)
        select(mode, for: display)
    }

    public func forgetConfirmedModes() {
        defaults.removeObject(forKey: Self.confirmedKey)
    }

    public func makeMain(_ display: CGDirectDisplayID) {
        Telemetry.shared.record(.screenMain)
        let origins = configurator.origins(of: displays.map(\.id))
        guard let shifted = DisplayArrangement.origins(makingMain: display, from: origins) else { return }
        lastError = errorMessage { try configurator.setOrigins(shifted) }
        reload()
    }

    public func setMirroring(_ on: Bool) {
        Telemetry.shared.record(.screenMirroring)
        let ids = displays.map(\.id)
        let main = ids.first { screens[$0]?.isMain == true } ?? ids.first
        lastError = errorMessage { try configurator.setMirroring(ids, to: on ? main : nil) }
        reload()
    }

    private func reload() {
        let ids = displays.map(\.id)
        let origins = configurator.origins(of: ids)
        isMirroring = !configurator.mirrors(of: ids).isEmpty
        screens = Dictionary(
            uniqueKeysWithValues: ids.map { id in
                let modes = configurator.modes(for: id, includeDuplicates: showAllModes)
                return (
                    id,
                    ScreenModes(
                        options: ModeCatalog.options(from: modes, showAll: showAllModes),
                        current: configurator.currentMode(for: id),
                        isMain: origins[id] == .zero,
                        defaultMode: modes.first(where: \.isDefault)
                    )
                )
            })
    }

    private func identity(of display: CGDirectDisplayID) -> DisplayIdentity? {
        displays.first { $0.id == display }?.identity
    }

    private func storageKey(_ identity: DisplayIdentity) -> String {
        "\(identity.vendor)-\(identity.model)-\(identity.serial)"
    }

    private func isConfirmed(_ mode: DisplayMode, on identity: DisplayIdentity) -> Bool {
        let confirmed = defaults.dictionary(forKey: Self.confirmedKey) as? [String: [String]] ?? [:]
        return confirmed[storageKey(identity)]?.contains(mode.key) == true
    }

    private func markConfirmed(_ mode: DisplayMode, on identity: DisplayIdentity) {
        guard !isConfirmed(mode, on: identity) else { return }
        var confirmed = defaults.dictionary(forKey: Self.confirmedKey) as? [String: [String]] ?? [:]
        confirmed[storageKey(identity), default: []].append(mode.key)
        defaults.set(confirmed, forKey: Self.confirmedKey)
    }
}
