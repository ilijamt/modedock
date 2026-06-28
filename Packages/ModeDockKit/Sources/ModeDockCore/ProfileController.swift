import CoreGraphics
import DisplayKit
import Foundation
import Observation
import os

private let log = Logger.screens

/// Saves the current screen setup as a profile and puts it back later, by hand or automatically
/// when the same screens are connected again.
@MainActor
@Observable
public final class ProfileController {
    public private(set) var profiles: [DisplayProfile] = [] {
        didSet { save() }
    }
    /// The profile being applied right now.
    public private(set) var applying: DisplayProfile.ID?
    public private(set) var lastError: String?

    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let configurator: DisplayConfiguring
    private let defaults: UserDefaults
    /// How long macOS gets to bring screens up or down before ModeDock reads them again.
    private let settleDelay: Duration
    /// The screens connected at the last auto-apply check; nil before the first one.
    private var lastConnected: Set<DisplayIdentity>?
    private static let storageKey = "displayProfiles"

    public init(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        configurator: DisplayConfiguring = CoreGraphicsDisplayConfigurator(),
        defaults: UserDefaults = .standard,
        settleDelay: Duration = .seconds(1.5)
    ) {
        self.screens = screens
        self.modes = modes
        self.brightness = brightness
        self.configurator = configurator
        self.defaults = defaults
        self.settleDelay = settleDelay
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                profiles = try JSONDecoder().decode([DisplayProfile].self, from: data)
            } catch {
                log.error("reading display profiles failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Editing

    /// Saves the current setup as a new profile.
    @discardableResult
    public func capture(name: String) -> DisplayProfile {
        let profile = DisplayProfile(name: name, mirroring: currentMirroring(), screens: currentScreens())
        profiles.append(profile)
        return profile
    }

    /// Replaces a profile's setup with the current one, keeping its name and options.
    public func update(_ id: DisplayProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].screens = currentScreens()
        profiles[index].mirroring = currentMirroring()
    }

    public func rename(_ id: DisplayProfile.ID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    public func setAutoApply(_ on: Bool, for id: DisplayProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].autoApply = on
    }

    public func delete(_ id: DisplayProfile.ID) {
        profiles.removeAll { $0.id == id }
    }

    // MARK: - Matching

    /// Whether the screens that are on, their resolutions and mirroring are what `profile` saved.
    /// Brightness and arrangement aren't compared.
    public func isActive(_ profile: DisplayProfile) -> Bool {
        let enabled = screens.screens.filter { $0.display.isEnabled && !$0.display.identity.isPlaceholder }
        guard Set(enabled.map(\.display.identity)) == Set(profile.enabledScreens.map(\.identity)),
            profile.mirroring == modes.isMirroring
        else { return false }
        return profile.enabledScreens.allSatisfy { saved in
            guard let key = saved.modeKey,
                let screen = enabled.first(where: { $0.display.identity == saved.identity })
            else { return true }
            let current = modes.screens[screen.id]?.current ?? configurator.currentMode(for: screen.id)
            return current?.key == key
        }
    }

    public var activeProfile: DisplayProfile? { profiles.first(where: isActive) }

    // MARK: - Applying

    /// Turns on the screens the profile wants on, sets their resolutions, turns off the others,
    /// then restores mirroring or the arrangement, and brightness. Screens in the profile that
    /// aren't connected are skipped.
    public func apply(_ profile: DisplayProfile) async {
        guard applying == nil else { return }
        applying = profile.id
        defer { applying = nil }
        log.info("applying profile \(profile.name, privacy: .public)")
        var errors: [String] = []
        func note(_ message: String?) {
            if let message, !errors.contains(message) { errors.append(message) }
        }

        var changedScreens = false
        for saved in profile.enabledScreens {
            guard let screen = connected(saved.identity), !screen.display.isEnabled else { continue }
            screens.setEnabled(true, screen: screen.id)
            note(screens.lastError)
            changedScreens = true
        }
        if changedScreens { await settle() }
        modes.refresh(displays: screens.screens.map(\.display))

        for saved in profile.enabledScreens {
            guard let key = saved.modeKey, let screen = connected(saved.identity), screen.display.isEnabled
            else { continue }
            note(errorMessage { try modes.applyKnownMode(key: key, for: screen.id) })
        }

        var turnedOff = false
        for saved in profile.screens where !saved.isEnabled {
            guard let screen = connected(saved.identity), screen.display.isEnabled else { continue }
            // ScreenController keeps the last screen on.
            screens.setEnabled(false, screen: screen.id)
            note(screens.lastError)
            turnedOff = true
        }
        if turnedOff { await settle() }
        changedScreens = changedScreens || turnedOff

        note(arrange(profile))
        modes.refresh(displays: screens.screens.map(\.display))

        if changedScreens { await brightness.refresh(displays: screens.screens.map(\.display)) }
        for saved in profile.enabledScreens {
            guard let value = saved.brightness, let screen = connected(saved.identity),
                let current = brightness.screens[screen.id], abs(current.value - value) > 0.005
            else { continue }
            brightness.set(value, for: screen.id)
            note(brightness.lastError)
        }

        lastError = errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    /// Applies the first automatic profile made for exactly the connected screens. Call after
    /// the screens change; it only acts when the set of connected screens is different from
    /// the last call, so applying a profile doesn't trigger another one.
    public func autoApplyIfNeeded() async {
        guard applying == nil else { return }
        let connected = connectedIdentities()
        guard connected != lastConnected else { return }
        lastConnected = connected
        guard let profile = profiles.first(where: { $0.autoApply && $0.identities == connected }) else { return }
        modes.refresh(displays: screens.screens.map(\.display))
        guard !isActive(profile) else { return }
        await apply(profile)
    }

    // MARK: - Helpers

    private func connected(_ identity: DisplayIdentity) -> ScreenController.Screen? {
        screens.screens.first { $0.display.identity == identity }
    }

    private func connectedIdentities() -> Set<DisplayIdentity> {
        Set(screens.screens.map(\.display.identity).filter { !$0.isPlaceholder })
    }

    private func settle() async {
        if settleDelay > .zero { try? await Task.sleep(for: settleDelay) }
        await screens.displaysChanged()
    }

    /// Mirrors onto the profile's main screen, or stops mirroring and moves the screens back to
    /// their saved positions. Returns the error message, if any.
    private func arrange(_ profile: DisplayProfile) -> String? {
        let enabled = screens.screens.filter(\.display.isEnabled)
        let ids = enabled.map(\.id)
        let isMirroring = !configurator.mirrors(of: ids).isEmpty
        let saved: [(CGDirectDisplayID, ProfileScreen)] = profile.enabledScreens.compactMap { saved in
            enabled.first { $0.display.identity == saved.identity }.map { ($0.id, saved) }
        }

        if profile.mirroring {
            guard !isMirroring, ids.count > 1 else { return nil }
            let main = saved.first { $0.1.origin == .zero }?.0 ?? ids.first
            return errorMessage { try configurator.setMirroring(ids, to: main) }
        }

        if isMirroring {
            if let message = errorMessage({ try configurator.setMirroring(ids, to: nil) }) { return message }
        }
        var origins = Dictionary(
            saved.compactMap { id, screen in screen.origin.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        // Only a complete layout: moving some screens and not others could make them overlap.
        guard origins.count == ids.count, !origins.isEmpty else { return nil }
        // The saved main screen isn't connected: make the first one main instead.
        if !origins.values.contains(.zero), let first = saved.first?.0,
            let shifted = DisplayArrangement.origins(makingMain: first, from: origins)
        {
            origins = shifted
        }
        guard origins != configurator.origins(of: ids) else { return nil }
        return errorMessage { try configurator.setOrigins(origins) }
    }

    private func currentMirroring() -> Bool {
        !configurator.mirrors(of: screens.screens.filter(\.display.isEnabled).map(\.id)).isEmpty
    }

    private func currentScreens() -> [ProfileScreen] {
        let connected = screens.screens.filter { !$0.display.identity.isPlaceholder }
        let origins = configurator.origins(of: connected.filter(\.display.isEnabled).map(\.id))
        return connected.map { screen in
            let display = screen.display
            guard display.isEnabled else {
                return ProfileScreen(identity: display.identity, name: display.name, isEnabled: false)
            }
            let origin = origins[screen.id]
            return ProfileScreen(
                identity: display.identity,
                name: display.name,
                isEnabled: true,
                modeKey: configurator.currentMode(for: screen.id)?.key,
                originX: origin.map { Double($0.x) },
                originY: origin.map { Double($0.y) },
                brightness: brightness.screens[screen.id]?.value
            )
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Self.storageKey)
        } catch {
            log.error("saving display profiles failed: \(error, privacy: .public)")
        }
    }
}
