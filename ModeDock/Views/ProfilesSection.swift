import KeyboardShortcuts
import ModeDockCore
import SwiftUI

/// The Profiles section in the Cards style: a card per profile, tap to switch to it.
struct ProfilesSection: View {
    let profiles: ProfileController
    let screens: ScreenController
    let modes: DisplayModeController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var edit: ProfileEdit?

    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 8) {
            if profiles.profiles.isEmpty { ProfilesEmptyText() }

            ForEach(profiles.profiles) { profile in
                Card {
                    // Over the corner rather than beside the content, so the screen lines keep the width.
                    ProfileButton(profile: profile, profiles: profiles)
                        .overlay(alignment: .topTrailing) { ProfileMoreButton(id: profile.id, edit: $edit) }
                }
                .contextMenu { ProfileMenu(profile: profile, profiles: profiles, edit: $edit) }
                // Under the card: text fields inside interactive glass crash SwiftUI on macOS 26.
                ProfileEditors(profiles: profiles, screens: screens, edit: $edit, scope: .profile(profile.id))
            }

            ProfileEditors(profiles: profiles, screens: screens, edit: $edit, scope: .saving)
            if edit == nil, !hidden.contains(.saveProfile) {
                ActionTile(title: "Save Current Setup", systemImage: "plus") { edit = .saving }
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
        let isActive = profiles.currentProfile?.id == profile.id
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
                        .padding(.trailing, 22)
                    if profile.mirroring || profile.autoApply {
                        Text(verbatim: profile.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProfileScreenLines(profile: profile)
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
    @State private var edit: ProfileEdit?

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
                        Button("Save Current Setup…") { edit = .saving }
                            .buttonStyle(.plain)
                        Spacer()
                    }
                }
            }
            ProfileEditors(profiles: profiles, screens: screens, edit: $edit, scope: .all)

            ErrorLabel(profiles.lastError)
        }
        .controlSize(.small)
        .modifier(ProfileModesRefresher(screens: screens, modes: modes))
    }

    private func row(_ profile: DisplayProfile) -> some View {
        let isActive = profiles.currentProfile?.id == profile.id
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
            ProfileMoreButton(id: profile.id, edit: $edit)
        }
        .help(isActive ? "This is the current setup." : "Switch to this setup: \(profile.summary).")
        .contextMenu { ProfileMenu(profile: profile, profiles: profiles, edit: $edit) }
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

/// Names a new profile, or renames one, inside the panel; a dialog would need ModeDock to
/// become the active app.
struct ProfileNameEditor: View {
    let initialName: String
    let actionTitle: String
    var caption: String?
    let onSave: (String) -> Void
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
                Button(actionTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            name = initialName
            fieldFocused = true
        }
        .onExitCommand(perform: onDone)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        onDone()
    }
}

/// What's open below a section's profiles.
enum ProfileEdit: Equatable {
    case saving
    /// The Update, Rename and Delete buttons.
    case actions(DisplayProfile.ID)
    case renaming(DisplayProfile.ID)
    case deleting(DisplayProfile.ID)
}

/// A profile's right-click menu in the panel.
private struct ProfileMenu: View {
    let profile: DisplayProfile
    let profiles: ProfileController
    @Binding var edit: ProfileEdit?

    var body: some View {
        Button("Update from Current Setup") {
            edit = nil
            profiles.update(profile.id)
        }
        Button("Rename…") { edit = .renaming(profile.id) }
        Button("Move Up") { profiles.move(profile.id, by: -1) }
            .disabled(profiles.profiles.first?.id == profile.id)
        Button("Move Down") { profiles.move(profile.id, by: 1) }
            .disabled(profiles.profiles.last?.id == profile.id)
        Divider()
        Button("Delete…", role: .destructive) { edit = .deleting(profile.id) }
    }
}

/// The ⋯ button on a profile that shows its Update, Rename and Delete buttons.
private struct ProfileMoreButton: View {
    let id: DisplayProfile.ID
    @Binding var edit: ProfileEdit?

    var body: some View {
        let isOpen = edit == .actions(id)
        Button {
            edit = isOpen ? nil : .actions(id)
        } label: {
            Image(systemName: isOpen ? "ellipsis.circle.fill" : "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Update, rename or delete this profile")
    }
}

/// Update, Rename and Delete for one profile.
private struct ProfileActionStrip: View {
    let profile: DisplayProfile
    let profiles: ProfileController
    @Binding var edit: ProfileEdit?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                profiles.update(profile.id)
                edit = nil
            } label: {
                Label("Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Replace this profile with the current screens, resolutions, arrangement and brightness.")
            Button {
                edit = .renaming(profile.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Spacer(minLength: 0)
            ProfileOrderButtons(profile: profile, profiles: profiles)
            Button(role: .destructive) {
                edit = .deleting(profile.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .controlSize(.small)
        .padding(8)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onExitCommand { edit = nil }
    }
}

/// Below a section's profiles: naming the current setup, renaming a profile, or confirming a
/// delete. Inside the panel, since a dialog would need ModeDock to become the active app.
private struct ProfileEditors: View {
    let profiles: ProfileController
    let screens: ScreenController
    @Binding var edit: ProfileEdit?
    let scope: Scope

    enum Scope {
        /// Only the save editor, at the end of the section.
        case saving
        /// Only the editors for this profile, right under it.
        case profile(DisplayProfile.ID)
        /// Everything, in one place.
        case all
    }

    var body: some View {
        switch edit {
        case .saving:
            if case .profile = scope {
                EmptyView()
            } else {
                saveEditor
            }
        case .actions(let id):
            if shows(id), let profile = profile(id) {
                ProfileActionStrip(profile: profile, profiles: profiles, edit: $edit)
            }
        case .renaming(let id):
            if shows(id), let profile = profile(id) {
                ProfileNameEditor(initialName: profile.name, actionTitle: "Rename") {
                    profiles.rename(id, to: $0)
                } onDone: {
                    edit = nil
                }
            }
        case .deleting(let id):
            if shows(id), let profile = profile(id) {
                deleteConfirmation(profile)
            }
        case nil:
            EmptyView()
        }
    }

    private func shows(_ id: DisplayProfile.ID) -> Bool {
        switch scope {
        case .saving: false
        case .profile(let shown): shown == id
        case .all: true
        }
    }

    private func profile(_ id: DisplayProfile.ID) -> DisplayProfile? {
        profiles.profiles.first { $0.id == id }
    }

    private var saveEditor: some View {
        ProfileNameEditor(
            initialName: profiles.suggestedName(screens: screens), actionTitle: "Save",
            caption: "Saves the screens that are on, their resolutions, arrangement and brightness."
        ) {
            profiles.capture(name: $0)
        } onDone: {
            edit = nil
        }
    }

    private func deleteConfirmation(_ profile: DisplayProfile) -> some View {
        HStack {
            Text(verbatim: "Delete \u{201C}\(profile.name)\u{201D}?")
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Cancel") { edit = nil }
            Button("Delete", role: .destructive) {
                profiles.deleteWithShortcut(profile.id)
                edit = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onExitCommand { edit = nil }
    }
}

/// Up and down arrows that change a profile's place in the list.
struct ProfileOrderButtons: View {
    let profile: DisplayProfile
    let profiles: ProfileController

    var body: some View {
        let index = profiles.profiles.firstIndex { $0.id == profile.id } ?? 0
        HStack(spacing: 2) {
            Button {
                profiles.move(profile.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move up. The order is the panel's and the Next Profile shortcut's.")
            Button {
                profiles.move(profile.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == profiles.profiles.count - 1)
            .help("Move down. The order is the panel's and the Next Profile shortcut's.")
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
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
