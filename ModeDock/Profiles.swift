import DisplayKit
import Foundation
import KeyboardShortcuts
import ModeDockCore
import Observation
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Applies the profile.
    static func profile(_ id: DisplayProfile.ID) -> Self { Self("profile-\(id.uuidString)") }

    /// Turns the screen on or off.
    static func toggleScreen(_ identity: DisplayIdentity) -> Self {
        Self("toggleScreen-\(identity.vendor)-\(identity.model)-\(identity.serial)")
    }
}

/// Marks the profile that applies by itself when its screens are connected.
struct AutoTag: View {
    var body: some View {
        Text("Auto")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.primary.opacity(0.1), in: Capsule())
            .fixedSize()
            .tip("Applied automatically when these exact screens are connected.")
    }
}

extension ProfileSystemSettings.Setting {
    var title: String {
        switch self {
        case .darkMode: String(localized: "Dark Mode")
        case .nightShift: String(localized: "Night Shift")
        case .trueTone: String(localized: "True Tone")
        case .dockAutoHide: String(localized: "Hide Dock")
        }
    }
}

extension ProfileSystemSettings {
    /// "Dark Mode Off · True Tone On", or nil when the profile sets none of them.
    var summary: String? {
        let parts = Setting.allCases.compactMap { setting -> String? in
            guard let on = self[setting] else { return nil }
            return on ? String(localized: "\(setting.title) On") : String(localized: "\(setting.title) Off")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension DisplayProfile {
    /// "2 screens · Mirrored · Automatic". Without "Automatic" where an Auto tag shows it.
    func summary(includingAutomatic: Bool = true) -> String {
        let count = enabledScreens.count
        var parts = [String(localized: "\(count) screens")]
        if mirroring { parts.append(String(localized: "Mirrored")) }
        if autoApply, includingAutomatic { parts.append(String(localized: "Automatic")) }
        if let settings = system.summary { parts.append(settings) }
        return parts.joined(separator: " · ")
    }

    var summary: String { summary() }

    /// Whether the summary says more than the number of screens, apart from being automatic.
    var hasExtras: Bool { mirroring || !system.isEmpty }

    /// "Built-in Display, LS28 (off)".
    var screenList: String {
        screens.map { $0.isEnabled ? $0.name : String(localized: "\($0.name) (off)") }.joined(separator: ", ")
    }

    @MainActor var shortcutText: String? { KeyboardShortcuts.Name.profile(id).shortcutText }
}

extension ProfileScreen {
    /// "1920 × 1080 · 60 Hz" from the saved mode key ("1920x1080@2x@60"); nil when there's none.
    var resolution: String? {
        let parts = modeKey?.split(separator: "@") ?? []
        let size = parts.first?.split(separator: "x") ?? []
        guard size.count == 2 else { return nil }
        var text = "\(size[0]) × \(size[1])"
        if parts.count > 1, let rate = parts.last, Int(rate) != nil { text += " · \(rate) Hz" }
        return text
    }

    /// "1920×1080 · 60Hz".
    var compactResolution: String? {
        resolution?.replacingOccurrences(of: " × ", with: "×").replacingOccurrences(of: " Hz", with: "Hz")
    }

    /// "1920 × 1080 · 60 Hz · 70%", or "1920 × 1080 · 60 Hz · 70% brightness" for tooltips.
    var details: String {
        guard isEnabled else { return String(localized: "Off") }
        var parts = [resolution].compactMap { $0 }
        if let brightness {
            parts.append(String(localized: "\(Int((brightness * 100).rounded()))% brightness"))
        }
        return parts.isEmpty ? String(localized: "On") : parts.joined(separator: " · ")
    }
}

/// One compact line per screen in a profile: its name, then resolution, refresh rate and brightness.
struct ProfileScreenLines: View {
    let profile: DisplayProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(profile.screens.enumerated()), id: \.offset) { _, screen in
                HStack(spacing: 6) {
                    Text(verbatim: screen.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    detail(screen)
                        .fixedSize()
                        .opacity(0.8)
                }
                .help("\(screen.name): \(screen.details)")
            }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func detail(_ screen: ProfileScreen) -> Text {
        guard screen.isEnabled else { return Text("Off") }
        // Tighter than `resolution`: the panel is narrow and the names need the room.
        var text = Text(verbatim: screen.compactResolution ?? String(localized: "On"))
        if let brightness = screen.brightness {
            text = Text("\(text) · \(Image(systemName: "sun.max"))\(Int((brightness * 100).rounded()))%")
        }
        return text
    }
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
                Telemetry.shared.record(.shortcutUsed)
                Task { await profiles.apply(profile) }
            }
        }
        for screen in screens.screens where !screen.display.identity.isPlaceholder {
            let identity = screen.display.identity
            wanted[.toggleScreen(identity)] = { [screens] in
                guard let screen = screens.screens.first(where: { $0.display.identity == identity }) else { return }
                Telemetry.shared.record(.shortcutUsed)
                Telemetry.shared.record(.screenToggled)
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
