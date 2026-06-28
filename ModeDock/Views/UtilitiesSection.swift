import ModeDockCore
import SwiftUI

/// One on/off utility, described once and drawn by every panel style.
struct UtilityToggle: Identifiable {
    let item: PanelItem
    let systemImage: String
    let isOn: Bool
    let set: @MainActor (Bool) -> Void

    var id: PanelItem { item }
    var title: String { item.title }

    /// The toggles this Mac supports, in panel order, without the hidden ones.
    @MainActor
    static func visible(_ utilities: UtilitiesController, hidden: Set<PanelItem>) -> [UtilityToggle] {
        let state = utilities.state
        let all: [UtilityToggle?] = [
            state.darkMode.map {
                UtilityToggle(
                    item: .darkMode, systemImage: "circle.lefthalf.filled", isOn: $0, set: utilities.setDarkMode)
            },
            state.nightShift.map {
                UtilityToggle(item: .nightShift, systemImage: "sunset.fill", isOn: $0, set: utilities.setNightShift)
            },
            state.trueTone.map {
                UtilityToggle(item: .trueTone, systemImage: "sun.max.fill", isOn: $0, set: utilities.setTrueTone)
            },
            state.dockAutoHide.map {
                UtilityToggle(
                    item: .dockAutoHide, systemImage: "dock.rectangle", isOn: $0, set: utilities.setDockAutoHide)
            },
            UtilityToggle(
                item: .desktopIcons, systemImage: "square.grid.2x2", isOn: state.desktopIcons,
                set: utilities.setDesktopIcons),
            UtilityToggle(
                item: .hiddenFiles, systemImage: "eye", isOn: state.hiddenFiles, set: utilities.setHiddenFiles),
        ]
        return all.compactMap { $0 }.filter { !hidden.contains($0.item) }
    }

    var help: String {
        switch item {
        case .darkMode: "Switch the whole Mac between dark and light appearance."
        case .nightShift: "Warmer colours on every screen."
        case .trueTone: "Adapt the screen's colours to the light around you."
        case .dockAutoHide: "Hide the Dock until the pointer reaches the screen edge."
        case .desktopIcons: "Show files on the desktop. Finder restarts to apply it."
        case .hiddenFiles: "Show hidden files in Finder. Finder restarts to apply it."
        default: ""
        }
    }
}

extension UtilitiesController {
    var ejectTitle: String {
        isEjecting ? "Ejecting…" : state.ejectableVolumes > 0 ? "Eject All (\(state.ejectableVolumes))" : "Eject All"
    }
}

/// The Utilities section in the Cards style: a grid of tiles.
struct UtilitiesSection: View {
    let utilities: UtilitiesController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var confirmingTrash = false

    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(UtilityToggle.visible(utilities, hidden: hidden)) { toggle in
                    ActionTile(title: toggle.title, systemImage: toggle.systemImage, isOn: toggle.isOn) {
                        toggle.set(!toggle.isOn)
                    }
                    .help(toggle.help)
                }
                if !hidden.contains(.emptyTrash) {
                    ActionTile(title: "Empty Trash", systemImage: "trash") { confirmingTrash = true }
                        .help("Empty the Trash. You'll be asked first.")
                }
                if !hidden.contains(.ejectDisks) {
                    ActionTile(title: utilities.ejectTitle, systemImage: "eject.fill") {
                        Task { await utilities.ejectAll() }
                    }
                    .disabled(utilities.state.ejectableVolumes == 0 || utilities.isEjecting)
                    .help("Eject every external disk and disk image.")
                }
            }

            if confirmingTrash {
                TrashConfirmation(utilities: utilities) { confirmingTrash = false }
            }
            ErrorLabel(utilities.lastError)
        }
        .onAppear(perform: utilities.refresh)
    }
}

/// "Empty the Trash?" inside the panel; a dialog would need ModeDock to become the active app.
private struct TrashConfirmation: View {
    let utilities: UtilitiesController
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text("Empty the Trash? This can't be undone.").font(.callout)
            Spacer()
            Button("Cancel", action: onDone)
            Button("Empty") {
                utilities.emptyTrash()
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The Utilities section in the Rows style.
struct RowsUtilitiesSection: View {
    let utilities: UtilitiesController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var confirmingTrash = false

    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 10) {
            let toggles = UtilityToggle.visible(utilities, hidden: hidden)
            if !toggles.isEmpty {
                RowGroup {
                    ForEach(Array(toggles.enumerated()), id: \.element.id) { index, toggle in
                        if index > 0 { Divider() }
                        Row {
                            Text(toggle.title)
                            Spacer()
                            Toggle(toggle.title, isOn: Binding(get: { toggle.isOn }, set: toggle.set))
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                        .help(toggle.help)
                    }
                }
            }

            if !hidden.contains(.emptyTrash) || !hidden.contains(.ejectDisks) {
                RowGroup {
                    if !hidden.contains(.emptyTrash) {
                        Row {
                            Button("Empty Trash…") { confirmingTrash = true }.buttonStyle(.plain)
                            Spacer()
                        }
                    }
                    if !hidden.contains(.ejectDisks) {
                        if !hidden.contains(.emptyTrash) { Divider() }
                        Row {
                            Button(utilities.ejectTitle) { Task { await utilities.ejectAll() } }
                                .buttonStyle(.plain)
                                .disabled(utilities.state.ejectableVolumes == 0 || utilities.isEjecting)
                            Spacer()
                        }
                    }
                }
            }

            if confirmingTrash {
                TrashConfirmation(utilities: utilities) { confirmingTrash = false }
            }
            ErrorLabel(utilities.lastError)
        }
        .controlSize(.small)
        .onAppear(perform: utilities.refresh)
    }
}
