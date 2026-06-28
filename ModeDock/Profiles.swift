import DisplayKit
import Foundation
import KeyboardShortcuts
import ModeDockCore
import Observation

extension KeyboardShortcuts.Name {
    /// Applies the profile.
    static func profile(_ id: DisplayProfile.ID) -> Self { Self("profile-\(id.uuidString)") }

    /// Turns the screen on or off.
    static func toggleScreen(_ identity: DisplayIdentity) -> Self {
        Self("toggleScreen-\(identity.vendor)-\(identity.model)-\(identity.serial)")
    }
}

extension DisplayProfile {
    /// "2 screens · Mirrored".
    var summary: String {
        let count = enabledScreens.count
        var parts = [count == 1 ? "1 screen" : "\(count) screens"]
        if mirroring { parts.append("Mirrored") }
        if autoApply { parts.append("Automatic") }
        return parts.joined(separator: " · ")
    }

    /// "Built-in Display, LS28 (off)".
    var screenList: String {
        screens.map { $0.isEnabled ? $0.name : "\($0.name) (off)" }.joined(separator: ", ")
    }

    @MainActor var shortcutText: String? { KeyboardShortcuts.Name.profile(id).shortcutText }
}

@MainActor
extension ProfileController {
    /// The names of the screens that are on, like "Built-in Display + LS28", numbered when a
    /// profile already has that name.
    func suggestedName(screens: ScreenController) -> String {
        let base = screens.screens.filter(\.display.isEnabled).map(\.display.name).joined(separator: " + ")
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) } ?? base
    }

    /// Deletes the profile together with its shortcut.
    func deleteWithShortcut(_ id: DisplayProfile.ID) {
        // The handler goes first: it finds the hotkey to unregister through the shortcut.
        KeyboardShortcuts.removeHandler(for: .profile(id))
        KeyboardShortcuts.setShortcut(nil, for: .profile(id))
        delete(id)
    }
}

/// Keeps a shortcut handler for every profile and every known screen, added and removed as
/// profiles are saved or deleted and screens come and go.
@MainActor
final class DynamicShortcuts {
    private let profiles: ProfileController
    private let screens: ScreenController
    private var registered: Set<KeyboardShortcuts.Name> = []

    init(profiles: ProfileController, screens: ScreenController) {
        self.profiles = profiles
        self.screens = screens
    }

    func start() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.start() }
        }
    }

    private func update() {
        var wanted: [KeyboardShortcuts.Name: () -> Void] = [:]
        for profile in profiles.profiles {
            let id = profile.id
            wanted[.profile(id)] = { [profiles] in
                guard let profile = profiles.profiles.first(where: { $0.id == id }) else { return }
                Task { await profiles.apply(profile) }
            }
        }
        for screen in screens.screens where !screen.display.identity.isPlaceholder {
            let identity = screen.display.identity
            wanted[.toggleScreen(identity)] = { [screens] in
                guard let screen = screens.screens.first(where: { $0.display.identity == identity }) else { return }
                screens.setEnabled(!screen.display.isEnabled, screen: screen.id)
            }
        }

        for name in registered.subtracting(wanted.keys) {
            KeyboardShortcuts.removeHandler(for: name)
        }
        for (name, action) in wanted where !registered.contains(name) {
            KeyboardShortcuts.onKeyUp(for: name, action: action)
        }
        registered = Set(wanted.keys)
    }
}
