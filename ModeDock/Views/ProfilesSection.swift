import KeyboardShortcuts
import ModeDockCore
import SwiftUI

/// The Profiles section in the Cards style: a card per profile, tap to switch to it.
struct ProfilesSection: View {
    let profiles: ProfileController
    let screens: ScreenController
    let modes: DisplayModeController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var naming = false

    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 8) {
            if profiles.profiles.isEmpty { ProfilesEmptyText() }

            ForEach(profiles.profiles) { profile in
                Card {
                    ProfileButton(profile: profile, profiles: profiles)
                }
            }

            // Below the cards: text fields inside interactive glass crash SwiftUI on macOS 26.
            if naming {
                SaveProfileEditor(profiles: profiles, screens: screens) { naming = false }
            } else if !hidden.contains(.saveProfile) {
                ActionTile(title: "Save Current Setup", systemImage: "plus") { naming = true }
                    .help("Save the screens that are on, their resolutions, arrangement and brightness.")
            }

            ErrorLabel(profiles.lastError)
        }
        .modifier(ProfileModesRefresher(screens: screens, modes: modes))
    }
}

/// One profile in a card: name, summary and whether it's the current setup.
private struct ProfileButton: View {
    let profile: DisplayProfile
    let profiles: ProfileController

    var body: some View {
        let isActive = profiles.isActive(profile)
        Button {
            Task { await profiles.apply(profile) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "rectangle.3.group")
                    .font(.system(size: 16))
                    .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: profile.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if profiles.applying == profile.id {
                    ProgressView().controlSize(.small)
                } else if let shortcut = profile.shortcutText {
                    Text(verbatim: shortcut).font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(profiles.applying != nil)
        .help(isActive ? "This is the current setup. Click to apply it again." : "Switch to this setup.")
    }
}

/// The Profiles section in the Rows style.
struct RowsProfilesSection: View {
    let profiles: ProfileController
    let screens: ScreenController
    let modes: DisplayModeController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var naming = false

    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 10) {
            if profiles.profiles.isEmpty {
                ProfilesEmptyText()
            } else {
                RowGroup {
                    ForEach(Array(profiles.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 { Divider() }
                        row(profile)
                    }
                }
            }

            if !hidden.contains(.saveProfile) {
                RowGroup {
                    Row {
                        Button("Save Current Setup…") { naming = true }.buttonStyle(.plain)
                        Spacer()
                    }
                }
            }
            if naming {
                SaveProfileEditor(profiles: profiles, screens: screens) { naming = false }
            }

            ErrorLabel(profiles.lastError)
        }
        .controlSize(.small)
        .modifier(ProfileModesRefresher(screens: screens, modes: modes))
    }

    private func row(_ profile: DisplayProfile) -> some View {
        let isActive = profiles.isActive(profile)
        return Row {
            Button {
                Task { await profiles.apply(profile) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .opacity(isActive ? 1 : 0)
                    Text(verbatim: profile.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if profiles.applying == profile.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(verbatim: profile.shortcutText ?? profile.summary).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(profiles.applying != nil)
        }
        .help(isActive ? "This is the current setup." : "Switch to this setup: \(profile.summary).")
    }
}

private struct ProfilesEmptyText: View {
    var body: some View {
        Text("Save the screens that are on, their resolutions and arrangement, and switch back to them in one click.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Names a new profile inside the panel; a dialog would need ModeDock to become the active app.
struct SaveProfileEditor: View {
    let profiles: ProfileController
    let screens: ScreenController
    /// Called after saving, and on Esc.
    let onDone: () -> Void

    @State private var name = ""
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(save)
                Button("Cancel", action: onDone)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            Text("Saves the screens that are on, their resolutions, arrangement and brightness.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            name = profiles.suggestedName(screens: screens)
            fieldFocused = true
        }
        .onExitCommand(perform: onDone)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        profiles.capture(name: trimmed)
        onDone()
    }
}

/// Which profile is current depends on the resolutions, so they're reloaded when the section
/// appears, even when the Screens section is hidden.
private struct ProfileModesRefresher: ViewModifier {
    let screens: ScreenController
    let modes: DisplayModeController
    @AppStorage(SettingsKey.showAllModes) private var showAllModes = false

    func body(content: Content) -> some View {
        content.onAppear { modes.refresh(displays: screens.screens.map(\.display), showAllModes: showAllModes) }
    }
}
