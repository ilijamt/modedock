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
    }

    /// A mode change waiting for the user to keep it; reverted automatically at `deadline`.
    public struct PendingChange: Equatable, Sendable {
        public let display: CGDirectDisplayID
        public let previous: DisplayMode
        public let new: DisplayMode
        public let deadline: Date
    }

    public private(set) var screens: [CGDirectDisplayID: ScreenModes] = [:]
    public private(set) var pending: PendingChange?
    public private(set) var isMirroring = false
    public private(set) var lastError: String?
    /// Called when a change needs confirmation, so the app can show the prompt.
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

    /// Reloads modes for the screens that are on.
    public func refresh(displays: [Display], showAllModes: Bool) {
        self.displays = displays.filter(\.isEnabled)
        self.showAllModes = showAllModes
        reload()
    }

    public func select(_ mode: DisplayMode, for display: CGDirectDisplayID) {
        guard pending == nil, let identity = identity(of: display) else { return }
        let previous = configurator.currentMode(for: display)
        guard previous?.id != mode.id else { return }
        // The mode the user is leaving works, so switching back to it never needs a prompt.
        if let previous, !isConfirmed(previous, on: identity) { markConfirmed(previous, on: identity) }
        do {
            try configurator.setMode(mode, for: display)
            lastError = nil
        } catch {
            report(error)
            return
        }
        reload()

        guard let previous, !isConfirmed(mode, on: identity) else { return }
        let change = PendingChange(
            display: display, previous: previous, new: mode,
            deadline: Date().addingTimeInterval(confirmationTimeout.seconds))
        pending = change
        onConfirmationNeeded?(change)
        revertTask = Task { [weak self, confirmationTimeout] in
            try? await Task.sleep(for: confirmationTimeout)
            guard !Task.isCancelled, self?.pending == change else { return }
            self?.revert()
        }
    }

    public func confirm() {
        guard let change = pending else { return }
        revertTask?.cancel()
        if let identity = identity(of: change.display) { markConfirmed(change.new, on: identity) }
        pending = nil
    }

    public func revert() {
        guard let change = pending else { return }
        revertTask?.cancel()
        pending = nil
        do {
            try configurator.setMode(change.previous, for: change.display)
        } catch {
            report(error)
        }
        reload()
    }

    public func makeMain(_ display: CGDirectDisplayID) {
        let origins = configurator.origins(of: displays.map(\.id))
        guard let shifted = DisplayArrangement.origins(makingMain: display, from: origins) else { return }
        do {
            try configurator.setOrigins(shifted)
            lastError = nil
        } catch {
            report(error)
        }
        reload()
    }

    /// Mirrors every screen that's on onto the main screen, or stops mirroring.
    public func setMirroring(_ on: Bool) {
        let ids = displays.map(\.id)
        let main = ids.first { screens[$0]?.isMain == true } ?? ids.first
        do {
            try configurator.setMirroring(ids, to: on ? main : nil)
            lastError = nil
        } catch {
            report(error)
        }
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
                        isMain: origins[id] == .zero
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
        var confirmed = defaults.dictionary(forKey: Self.confirmedKey) as? [String: [String]] ?? [:]
        confirmed[storageKey(identity), default: []].append(mode.key)
        defaults.set(confirmed, forKey: Self.confirmedKey)
    }

    private func report(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension Duration {
    fileprivate var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
