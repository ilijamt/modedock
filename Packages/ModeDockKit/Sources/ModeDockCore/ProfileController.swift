import CoreGraphics
import DisplayKit
import Foundation
import Observation
import os

private let log = AppLog.screens

@MainActor
@Observable
public final class ProfileController {
    public private(set) var profiles: [DisplayProfile] = [] {
        didSet { save() }
    }
    public private(set) var applying: DisplayProfile.ID?
    public private(set) var lastError: String? {
        // Only the error kind is counted, never its text.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorProfile) } }
    }

    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let configurator: DisplayConfiguring
    private let defaults: UserDefaults
    /// Time macOS gets to bring screens up or down before ModeDock reads them again.
    private let settleDelay: Duration
    public var utilities: UtilitiesController?
    private var lastConnected: Set<DisplayIdentity>?
    /// Wins when several profiles match the screens.
    private var lastUsed: DisplayProfile.ID?
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
                log.error("reading display profiles failed: \(error)")
            }
        }
    }

    @discardableResult
    public func capture(name: String) -> DisplayProfile {
        Telemetry.shared.record(.profileSave)
        let profile = DisplayProfile(name: name, mirroring: currentMirroring(), screens: currentScreens())
        profiles.append(profile)
        lastUsed = profile.id
        return profile
    }

    public func update(_ id: DisplayProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].screens = currentScreens()
        profiles[index].mirroring = currentMirroring()
        if let utilities {
            utilities.refresh()
            for setting in ProfileSystemSettings.Setting.allCases where profiles[index].system[setting] != nil {
                profiles[index].system[setting] =
                    utilities.state[keyPath: setting.state] ?? profiles[index].system[setting]
            }
        }
        lastUsed = id
    }

    public func editScreen(
        _ identity: DisplayIdentity, in id: DisplayProfile.ID, _ change: (inout ProfileScreen) -> Void
    ) {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
            let screen = profiles[index].screens.firstIndex(where: { $0.identity == identity })
        else { return }
        change(&profiles[index].screens[screen])
    }

    public func setSystemSetting(_ setting: ProfileSystemSettings.Setting, to value: Bool?, for id: DisplayProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].system[setting] = value
    }

    public func rename(_ id: DisplayProfile.ID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    /// Only one profile applies automatically for a set of screens.
    public func setAutoApply(_ on: Bool, for id: DisplayProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        var updated = profiles
        if on {
            for other in updated.indices where other != index && updated[other].identities == updated[index].identities
            {
                updated[other].autoApply = false
            }
        }
        updated[index].autoApply = on
        profiles = updated
    }

    public func automaticProfile(sharingScreensWith id: DisplayProfile.ID) -> DisplayProfile? {
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        return profiles.first { $0.id != id && $0.autoApply && $0.identities == profile.identities }
    }

    public func move(_ id: DisplayProfile.ID, to target: DisplayProfile.ID) {
        guard id != target, let from = profiles.firstIndex(where: { $0.id == id }),
            let to = profiles.firstIndex(where: { $0.id == target })
        else { return }
        var updated = profiles
        updated.insert(updated.remove(at: from), at: to)
        profiles = updated
    }

    /// The order of the panel and of the Next Profile shortcut.
    public func move(_ id: DisplayProfile.ID, by offset: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == id }), profiles.indices.contains(index + offset)
        else { return }
        var updated = profiles
        updated.swapAt(index, index + offset)
        profiles = updated
    }

    public func replaceAll(with profiles: [DisplayProfile]) {
        self.profiles = profiles
        lastUsed = nil
    }

    public func delete(_ id: DisplayProfile.ID) {
        profiles.removeAll { $0.id == id }
    }

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
        } && (utilities.map { profile.system.matches($0.state) } ?? true)
    }

    static let brightnessTolerance = 0.05

    /// Brightness on screens that set it automatically is ignored. When several match, the one applied
    /// or saved last wins, or else the one whose brightness is closest.
    public var currentProfile: DisplayProfile? {
        let matching = profiles.filter { isActive($0) && brightnessDistance($0) != nil }
        guard matching.count > 1 else { return matching.first }
        if let lastUsed, let profile = matching.first(where: { $0.id == lastUsed }) { return profile }
        return matching.min { (brightnessDistance($0) ?? 0) < (brightnessDistance($1) ?? 0) }
    }

    private func brightnessDistance(_ profile: DisplayProfile) -> Double? {
        var total = 0.0
        for saved in profile.enabledScreens {
            guard let value = saved.brightness, let screen = connected(saved.identity),
                let current = brightness.screens[screen.id], current.autoBrightness != true
            else { continue }
            let difference = abs(current.value - value)
            if difference > Self.brightnessTolerance { return nil }
            total += difference
        }
        return total
    }

    public func fitsConnectedScreens(_ profile: DisplayProfile) -> Bool {
        profile.identities == connectedIdentities()
    }

    public func apply(_ profile: DisplayProfile) async {
        Telemetry.shared.record(.profileApply)
        await perform(profile)
    }

    private func perform(_ profile: DisplayProfile) async {
        guard applying == nil else { return }
        applying = profile.id
        lastUsed = profile.id
        defer { applying = nil }
        log.info("applying profile \(profile.name)")
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

        if let utilities, !profile.system.isEmpty {
            utilities.refresh()
            for setting in ProfileSystemSettings.Setting.allCases {
                guard let wanted = profile.system[setting], let current = utilities.state[keyPath: setting.state],
                    current != wanted
                else { continue }
                utilities.set(setting, to: wanted)
                note(utilities.lastError)
            }
        }

        lastError = errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    /// Only acts when the set of connected screens differs from the last call, so applying a profile
    /// doesn't trigger another one.
    public func autoApplyIfNeeded() async {
        guard applying == nil else { return }
        let connected = connectedIdentities()
        guard connected != lastConnected else { return }
        let isLaunch = lastConnected == nil
        lastConnected = connected
        guard let profile = profiles.first(where: { $0.autoApply && $0.identities == connected }) else { return }
        modes.refresh(displays: screens.screens.map(\.display))
        // After a screen is plugged in or out the whole profile is applied, which also restores
        // its brightness. At launch nothing changed, so a setup that already matches is kept.
        if isLaunch, isActive(profile) { return }
        Telemetry.shared.record(.profileAutoApply)
        await perform(profile)
    }

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
            log.error("saving display profiles failed: \(error)")
        }
    }
}
