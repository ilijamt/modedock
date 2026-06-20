import KeyboardShortcuts
import ModeDockCore
import SwiftUI

/// The Settings tabs, in order. Each becomes a toolbar item in the Settings window.
enum SettingsTab: String, CaseIterable {
    case general, menu, displays, shortcuts, about

    var title: String {
        switch self {
        case .general: "General"
        case .menu: "Menu"
        case .displays: "Displays"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menu: "menubar.rectangle"
        case .displays: "display.2"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }

    /// Fixed sizes keep the window from jumping between tabs by a few points.
    var height: CGFloat {
        switch self {
        case .general: 340
        case .menu: 560
        case .displays: 500
        case .shortcuts: 150
        case .about: 250
        }
    }

    @MainActor @ViewBuilder
    func content(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController
    ) -> some View {
        switch self {
        case .general: GeneralSettingsView(modes: modes, power: power)
        case .menu: MenuSettingsView()
        case .displays: DisplaySettingsView(screens: screens, modes: modes, brightness: brightness)
        case .shortcuts: ShortcutSettingsView()
        case .about: AboutView(screens: screens, modes: modes)
        }
    }
}

private struct GeneralSettingsView: View {
    let modes: DisplayModeController
    let power: PowerController
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKey.keepScreensOn) private var keepScreensOn = true
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: appearance) { AppAppearance.apply() }

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            if let error = launchAtLogin.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section {
                Toggle(
                    "Keep screens on during Keep Awake",
                    isOn: Binding(
                        get: { keepScreensOn }, set: { KeepAwakeSettings.setKeepScreensOn($0, power: power) })
                )
            } footer: {
                Text("When off, the screens can still go dark, but the Mac stays awake. Also in the Keep Awake menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("ModeDock settings") {
                    Button("Reset Settings…") { confirmingReset = true }
                }
            } footer: {
                Text(
                    "Puts every ModeDock setting and keyboard shortcut back to its default. Screens are "
                        + "reset in Displays. Launch at login stays as it is."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
        .confirmationDialog("Reset ModeDock settings?", isPresented: $confirmingReset) {
            Button("Reset Settings", role: .destructive) { ScreenDefaults.resetSettings(modes: modes) }
        } message: {
            Text(
                "Appearance, panel style, menu sections, display options and shortcuts go back to their "
                    + "defaults. ModeDock will ask again before keeping a new resolution."
            )
        }
    }
}

private struct MenuSettingsView: View {
    @AppStorage(SettingsKey.sectionOrder) private var sectionOrder = ""
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(SettingsKey.collapsedSections) private var collapsedSections = ""
    @State private var dragging: MenuSection?
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue

    private var layout: MenuLayout {
        MenuLayout(order: sectionOrder, hidden: hiddenSections, collapsed: collapsedSections)
    }

    var body: some View {
        Form {
            Section {
                Picker("Panel style", selection: $panelStyle) {
                    ForEach(PanelStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text((PanelStyle(rawValue: panelStyle) ?? .cards).summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // A grouped Form doesn't support onMove on macOS, so rows are dragged and dropped instead.
                ForEach(layout.order) { section in
                    HStack {
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Image(systemName: section.systemImage).frame(width: 22)
                            Text(section.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            // The open hand says "you can grab this", as in other reorderable lists.
                            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                        }
                        .help("Drag to change the order")
                        Picker("Starts", selection: expansion(of: section)) {
                            Text("Open").tag(true)
                            Text("Collapsed").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(layout.hidden.contains(section))
                        .help("Whether the section is open or collapsed in the panel")
                        Toggle("Show \(section.title)", isOn: visibility(of: section))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .opacity(dragging == section ? 0.4 : 1)
                    .onDrag {
                        dragging = section
                        return NSItemProvider(object: section.rawValue as NSString)
                    } preview: {
                        Label(section.title, systemImage: section.systemImage).padding(6)
                    }
                    .onDrop(
                        of: [.text],
                        delegate: SectionDropDelegate(target: section, dragging: $dragging) { move($0, to: $1) }
                    )
                    .contextMenu {
                        Button("Move Up") { move(section, by: -1) }
                            .disabled(layout.order.first == section)
                        Button("Move Down") { move(section, by: 1) }
                            .disabled(layout.order.last == section)
                    }
                }
            } header: {
                Text("Sections")
            } footer: {
                Text(
                    "Show or hide sections and choose whether they start open or collapsed. Drag them, or right-click one, to change their order. Clicking a section title in the panel also opens or collapses it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(layout.order) { section in
                Section {
                    ForEach(PanelItem.allCases.filter { $0.section == section }) { item in
                        Toggle(item.title, isOn: itemVisibility(item))
                    }
                } header: {
                    Text("Show in \(section.title)")
                }
                .disabled(layout.hidden.contains(section))
            }
        }
        .formStyle(.grouped)
        // A drop anywhere else in the window ends the drag, so the dragged row doesn't stay faded.
        .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
    }

    /// Puts `section` where `target` is, shifting the others.
    private func move(_ section: MenuSection, to target: MenuSection) {
        var order = layout.order
        guard section != target, let from = order.firstIndex(of: section),
            let to = order.firstIndex(of: target)
        else { return }
        order.remove(at: from)
        order.insert(section, at: to)
        withAnimation(.snappy(duration: 0.2)) { sectionOrder = CommaSeparated.encode(order) }
    }

    private func move(_ section: MenuSection, by offset: Int) {
        let order = layout.order
        guard let index = order.firstIndex(of: section), order.indices.contains(index + offset) else { return }
        move(section, to: order[index + offset])
    }

    private func itemVisibility(_ item: PanelItem) -> Binding<Bool> {
        Binding(
            get: { !PanelItem.hidden(in: hiddenItems).contains(item) },
            set: { visible in
                var hidden = PanelItem.hidden(in: hiddenItems)
                hidden.set(item, contains: !visible)
                hiddenItems = CommaSeparated.encode(hidden.sorted { $0.rawValue < $1.rawValue })
            }
        )
    }

    private func expansion(of section: MenuSection) -> Binding<Bool> {
        Binding(
            get: { !layout.collapsed.contains(section) },
            set: { open in
                var collapsed = layout.collapsed
                collapsed.set(section, contains: !open)
                collapsedSections = CommaSeparated.encode(collapsed)
            }
        )
    }

    private func visibility(of section: MenuSection) -> Binding<Bool> {
        Binding(
            get: { !layout.hidden.contains(section) },
            set: { visible in
                var hidden = layout.hidden
                hidden.set(section, contains: !visible)
                hiddenSections = CommaSeparated.encode(hidden)
            }
        )
    }
}

private struct DisplaySettingsView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.showAllModes) private var showAllModes = false
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false
    @AppStorage(SettingsKey.ddcWriteInterval) private var ddcWriteInterval = SettingsKey.ddcWriteIntervalDefault

    var body: some View {
        Form {
            Section {
                Toggle("Show all resolutions", isOn: $showAllModes)
            } footer: {
                Text(
                    "Includes other aspect ratios, low-resolution versions of HiDPI sizes, and modes "
                        + "macOS doesn't offer for the desktop. Some may not display correctly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Monitor brightness updates") {
                    HStack {
                        Slider(value: intervalStep, in: 0...Double(steps.count - 1), step: 1)
                        Text(verbatim: "\(ddcWriteInterval) ms")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } footer: {
                Text(
                    "How often ModeDock sends a new brightness to an external monitor while you drag. "
                        + "Monitors react differently: try a few values and keep the one that looks smoothest."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(screens.screens.filter(\.display.isEnabled)) { screen in
                    LabeledContent(screen.display.name) {
                        Button("Reset to Defaults") {
                            ScreenDefaults.reset(screen.id, modes: modes, brightness: brightness)
                        }
                        .disabled(ScreenDefaults.isAtDefault(screen.id, modes: modes, brightness: brightness))
                    }
                }
                LabeledContent("All screens") {
                    Button("Reset All") {
                        ScreenDefaults.resetAll(screens: screens, modes: modes, brightness: brightness)
                    }
                }
            } header: {
                Text("Reset")
            } footer: {
                Text(
                    "Goes back to the resolution and refresh rate macOS picks for the screen, removes "
                        + "software dimming, and turns automatic brightness back on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Standby for external monitors", isOn: $showDDCStandby)
            } footer: {
                Text(
                    "Standby powers a monitor down over DDC. Some monitors then only wake when you press "
                        + "their power button. Turning a screen off is the safer choice."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Keeps the reset buttons' enabled state current while the window is open.
        .modifier(ModeRefresher(controller: screens, modes: modes, brightness: brightness))
    }

    private var steps: [Int] { SettingsKey.ddcWriteIntervalSteps }

    /// The slider moves through the preset steps rather than every millisecond.
    private var intervalStep: Binding<Double> {
        Binding(
            get: {
                let nearest = steps.indices.min {
                    abs(steps[$0] - ddcWriteInterval) < abs(steps[$1] - ddcWriteInterval)
                }
                return Double(nearest ?? 0)
            },
            set: { ddcWriteInterval = steps[Int($0.rounded())] })
    }
}

private struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Open ModeDock:", name: .togglePanel)
            KeyboardShortcuts.Recorder("Turn all screens on:", name: .turnAllScreensOn)
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.2")
                .font(.system(size: 40))
            Text("ModeDock").font(.title2.bold())
            Text(verbatim: "Version \(Bundle.main.versionString)").foregroundStyle(.secondary)
            Text("Free and open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = URL(string: "https://github.com/ilijamt/modedock") {
                Link("github.com/ilijamt/modedock", destination: url)
                    .font(.caption)
            }
            Button(copied ? "Copied" : "Copy Diagnostics") {
                Diagnostics.copy(screens: screens, modes: modes)
                copied = true
            }
            .padding(.top, 8)
            .help("Copy details about your screens and macOS, to paste into a bug report.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Covers the gaps between rows and the rest of the window: keeps the move cursor there and ends
/// the drag on drop, so the dragged row doesn't stay faded.
private struct EndDragDelegate: DropDelegate {
    @Binding var dragging: MenuSection?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        NSCursor.closedHand.set()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Reorders the section rows while dragging, as the pointer passes over them, and shows the move
/// cursor rather than the copy one.
private struct SectionDropDelegate: DropDelegate {
    let target: MenuSection
    @Binding var dragging: MenuSection?
    let move: (MenuSection, MenuSection) -> Void

    func dropEntered(info: DropInfo) {
        if let dragging, dragging != target { move(dragging, target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        NSCursor.closedHand.set()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
