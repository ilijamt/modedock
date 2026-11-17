import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, menu, displays, profiles, screenshots, shortcuts, permissions, advanced, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .menu: String(localized: "Menu")
        case .displays: String(localized: "Displays")
        case .profiles: String(localized: "Profiles")
        case .screenshots: String(localized: "Capture")
        case .shortcuts: String(localized: "Shortcuts")
        case .permissions: String(localized: "Permissions")
        case .advanced: String(localized: "Advanced")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menu: "menubar.rectangle"
        case .displays: "display.2"
        case .profiles: "rectangle.3.group"
        case .screenshots: "camera.viewfinder"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }

    @MainActor @ViewBuilder
    func content(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController, profiles: ProfileController, screenshots: ScreenshotController
    ) -> some View {
        switch self {
        case .general: GeneralSettingsView(screens: screens, profiles: profiles, power: power)
        case .menu: MenuSettingsView()
        case .displays: DisplaySettingsView(screens: screens, modes: modes, brightness: brightness)
        case .profiles: ProfileSettingsView(profiles: profiles, screens: screens, modes: modes)
        case .screenshots: ScreenshotSettingsView(screenshots: screenshots)
        case .shortcuts: ShortcutSettingsView(screens: screens)
        case .permissions: PermissionsSettingsView(screenshots: screenshots)
        case .advanced: AdvancedSettingsView(screens: screens, modes: modes, profiles: profiles)
        case .about: AboutView(screens: screens, modes: modes)
        }
    }
}

private struct GeneralSettingsView: View {
    let screens: ScreenController
    let profiles: ProfileController
    let power: PowerController
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(SettingsKey.keepScreensOn) private var keepScreensOn = true

    var body: some View {
        SettingsPage {
            LabeledContent("Setup:") {
                Button("Setup Assistant…") { NotificationCenter.default.post(name: .openSetupAssistant, object: nil) }
                    .help("Walks you through the main settings, one question at a time.")
            }

            SettingsGap()

            Picker("Appearance:", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            .onChange(of: appearance) { AppAppearance.apply() }

            LanguagePicker()

            SettingsGap()

            Toggle(
                "Launch ModeDock at login",
                isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
            )
            .labeledSettingsRow("Startup:")
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            SettingsGap()

            Toggle(
                "Keep screens on",
                isOn: Binding(get: { keepScreensOn }, set: { KeepAwakeSettings.setKeepScreensOn($0, power: power) })
            )
            .labeledSettingsRow("Keep Awake:")
            .help("When off, screens can sleep while the Mac stays awake.")

            SettingsGap()

            UpdatesSection()

            SettingsGap()

            UsageDataSection(screens: screens, profiles: profiles, power: power)
        }
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct AdvancedSettingsView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    let profiles: ProfileController
    @State private var confirmingReset = false

    var body: some View {
        SettingsPage {
            ConfigurationSection(profiles: profiles)

            SettingsGap()

            LabeledContent("Reset:") {
                Button("Reset Settings…") { confirmingReset = true }
                    .help("Every setting and shortcut goes back to its default. Profiles are kept.")
            }

            SettingsGap()

            DebugLogSection()

            SettingsGap()

            LabeledContent("Bug reports:") {
                CopyButton("Copy Diagnostics") { Diagnostics.copy(screens: screens, modes: modes) }
                .help("Copy screen and macOS details for a bug report.")
            }
        }
        .confirmationDialog("Reset ModeDock settings?", isPresented: $confirmingReset) {
            Button("Reset Settings", role: .destructive) { ScreenDefaults.resetSettings(modes: modes) }
        } message: {
            Text("Every setting and shortcut goes back to its default. Profiles are kept.")
        }
    }
}

private struct PermissionsSettingsView: View {
    let screenshots: ScreenshotController
    @State private var accessibility = BrightnessKeys.isTrusted
    @State private var automation = PermissionStatus.notAsked

    var body: some View {
        SettingsPage {
            LabeledContent("Accessibility:") {
                HStack {
                    PermissionLabel(status: accessibility ? .allowed : .denied)
                    if !accessibility {
                        Group {
                            Button("Allow…") { BrightnessKeys.requestAccess() }
                            Button("Open Settings") { BrightnessKeys.openPrivacySettings() }
                        }
                        .controlSize(.small)
                    }
                }
            }
            SettingsNote("The brightness keys need this to change every screen.")

            SettingsGap()

            LabeledContent("Screen Recording:") {
                HStack {
                    PermissionLabel(status: screenshots.hasPermission ? .allowed : .denied)
                    if !screenshots.hasPermission { ScreenRecordingButtons(controller: screenshots) }
                }
            }
            SettingsNote(
                "Screenshots need this. macOS calls it Screen & System Audio Recording, but ModeDock doesn't record audio. You may need to reopen ModeDock after allowing it."
            )

            SettingsGap()

            LabeledContent("Automation:") {
                HStack {
                    PermissionLabel(status: automation)
                    Group {
                        switch automation {
                        case .allowed: EmptyView()
                        case .notAsked: Button("Allow…") { askFinder() }
                        case .denied: Button("Open Settings") { FinderAutomation.openPrivacySettings() }
                        }
                    }
                    .controlSize(.small)
                }
            }
            SettingsNote("Empty Trash needs this to ask Finder.")
        }
        .pollingPermissions {
            accessibility = BrightnessKeys.isTrusted
            screenshots.refreshPermission()
            automation = await Task.detached { FinderAutomation.status() }.value
        }
    }

    private func askFinder() {
        Task {
            automation = await Task.detached { FinderAutomation.status(askIfNeeded: true) }.value
        }
    }
}

private struct PermissionLabel: View {
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .allowed:
            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Label("Not allowed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notAsked:
            Label("Not asked yet", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

extension View {
    func labeledSettingsRow(_ label: LocalizedStringKey) -> some View {
        LabeledContent {
            self
        } label: {
            Text(label)
        }
    }
}

private struct MenuSettingsView: View {
    @AppStorage(SettingsKey.sectionOrder) private var sectionOrder = ""
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(SettingsKey.collapsedSections) private var collapsedSections = ""
    @State private var dragging: MenuSection?
    @State private var expanded: Set<MenuSection> = []
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue
    @AppStorage(PanelLayout.key) private var panelLayout = PanelLayout.tabs.rawValue

    private var layout: MenuLayout {
        MenuLayout(order: sectionOrder, hidden: hiddenSections, collapsed: collapsedSections)
    }

    var body: some View {
        SettingsPage {
            Picker("Panel style:", selection: $panelStyle) {
                ForEach(PanelStyle.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            .help(LocalizedStringKey((PanelStyle(rawValue: panelStyle) ?? .cards).summary))

            Picker("Layout:", selection: $panelLayout) {
                ForEach(PanelLayout.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            .disabled(panelStyle == PanelStyle.menu.rawValue)
            .help(LocalizedStringKey((PanelLayout(rawValue: panelLayout) ?? .tabs).summary))

            SettingsGap()

            LabeledContent("Sections:") {
                VStack(spacing: 0) {
                    // A Form doesn't support onMove on macOS, so rows are dragged and dropped instead.
                    ForEach(Array(layout.order.enumerated()), id: \.element) { index, section in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 6) {
                            sectionRow(section)
                            if expanded.contains(section) {
                                sectionDetails(section)
                                    .padding(.leading, 46)
                                    .padding(.bottom, 4)
                                    .disabled(layout.hidden.contains(section))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .opacity(dragging == section ? 0.4 : 1)
                        .onDrop(
                            of: [.text],
                            delegate: ReorderDropDelegate(target: section, dragging: $dragging) { move($0, to: $1) }
                        )
                        .contextMenu {
                            Button("Move Up") { move(section, by: -1) }
                                .disabled(layout.order.first == section)
                            Button("Move Down") { move(section, by: 1) }
                                .disabled(layout.order.last == section)
                        }
                    }
                }
                .frame(width: 330)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            .help("Turn sections on or off and choose what each shows. Drag to reorder.")
        }
        // A drop anywhere else in the window ends the drag, so the dragged row doesn't stay faded.
        .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
    }

    private func sectionRow(_ section: MenuSection) -> some View {
        let items = PanelItem.allCases.filter { $0.section == section }
        let shown = items.filter { !PanelItem.hidden(in: hiddenItems).contains($0) }.count
        let isOpen = expanded.contains(section)
        return HStack(spacing: 8) {
            Toggle("Show \(section.title)", isOn: visibility(of: section))
                .labelsHidden()
            HStack(spacing: 8) {
                Image(systemName: section.systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(section.title)
                Spacer()
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            }
            .reorderHandle(section, id: section.rawValue, dragging: $dragging) {
                Label(section.title, systemImage: section.systemImage).padding(6)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.set(section, contains: !isOpen) }
            } label: {
                HStack(spacing: 4) {
                    Text("\(shown) of \(items.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the options" : "Choose what this section shows")
        }
    }

    private func sectionDetails(_ section: MenuSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                alignment: .leading, spacing: 4
            ) {
                ForEach(PanelItem.allCases.filter { $0.section == section }) { item in
                    Toggle(item.title, isOn: itemVisibility(item))
                        .font(.callout)
                }
            }
            if panelLayout == PanelLayout.list.rawValue {
                Toggle("Starts open", isOn: expansion(of: section))
                    .font(.callout)
                    .help("Open or collapsed when the panel opens")
            }
        }
    }

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
        SettingsPage {
            Toggle("Show all resolutions", isOn: $showAllModes)
                .labeledSettingsRow("Resolutions:")
                .help("Adds other aspect ratios, low-resolution sizes and modes macOS hides.")
            SettingsNote("Some may not display correctly.")

            SettingsGap()

            BrightnessKeysToggle()
            LabeledContent("Monitor updates:") {
                HStack {
                    Slider(value: intervalStep, in: 0...Double(steps.count - 1), step: 1)
                        .frame(width: 200)
                    Text(verbatim: "\(ddcWriteInterval) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help("How often brightness is sent to external monitors while dragging. Pick whatever looks smoothest.")

            SettingsGap()

            Toggle("Show Standby for external monitors", isOn: $showDDCStandby)
                .labeledSettingsRow("Standby:")
                .help("Puts a monitor into standby over DDC.")
            SettingsNote("Some monitors only wake with their power button.")

            SettingsGap()

            LabeledContent("Reset:") {
                Menu("Reset Screens") {
                    ForEach(screens.screens.filter(\.display.isEnabled)) { screen in
                        Button(screen.display.name) {
                            ScreenDefaults.reset(screen.id, modes: modes, brightness: brightness)
                        }
                        .disabled(ScreenDefaults.isAtDefault(screen.id, modes: modes, brightness: brightness))
                    }
                    Divider()
                    Button("All Screens") {
                        ScreenDefaults.resetAll(screens: screens, modes: modes, brightness: brightness)
                    }
                }
                .fixedSize()
                .help(
                    "Restores the default resolution and refresh rate, removes dimming and turns automatic brightness back on."
                )
            }
        }
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
    let screens: ScreenController
    @AppStorage(SettingsKey.profileCycleScope) private var profileCycleScope = ProfileCycleScope.connected.rawValue
    @State private var tab = Tab(launchArgument: true) ?? .screens

    enum Tab: String, CaseIterable, Identifiable {
        case screens, power, capture

        var id: String { rawValue }

        var title: String {
            switch self {
            case .screens: String(localized: "Panel & Screens")
            case .power: String(localized: "Power & Utilities")
            case .capture: String(localized: "Capture")
            }
        }
    }

    var body: some View {
        SettingsSubTabs(tabs: Tab.allCases, title: \.title, selection: $tab) { tab in
            switch tab {
            case .screens:
                SettingsPage {
                    ShortcutRecorder("Open ModeDock:", name: .togglePanel)
                    SettingsGap()
                    Group {
                        ShortcutRecorder("Brightness up:", name: .brightnessUp)
                        ShortcutRecorder("Brightness down:", name: .brightnessDown)
                    }
                    .help("Changes every screen.")
                    ShortcutRecorder("Sleep screens:", name: .sleepScreens)
                    ShortcutRecorder("Mirror on or off:", name: .toggleMirror)
                    ShortcutRecorder("Turn all screens on:", name: .turnAllScreensOn)
                    let named = screens.screens.filter { !$0.display.identity.isPlaceholder }
                    ForEach(Array(named.enumerated()), id: \.element.id) { index, screen in
                        ShortcutRecorder(
                            index == 0 ? "Turn on or off:" : "", name: .toggleScreen(screen.display.identity),
                            detail: screen.display.name)
                    }
                    SettingsGap()
                    ShortcutRecorder("Next profile:", name: .nextProfile)
                    Picker("Cycle through:", selection: $profileCycleScope) {
                        ForEach(ProfileCycleScope.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .fixedSize()
                    .help(
                        "Each press moves to the next profile, and the highlighted one is applied when you stop. \"Connected screens\" lists only profiles for the screens plugged in now."
                    )
                }
            case .power:
                SettingsPage {
                    ShortcutRecorder("Keep Awake on or off:", name: .toggleKeepAwake)
                    ShortcutRecorder("Dark Mode on or off:", name: .toggleDarkMode)
                    ShortcutRecorder("Night Shift on or off:", name: .toggleNightShift)
                    ShortcutRecorder("True Tone on or off:", name: .toggleTrueTone)
                    ShortcutRecorder("Desktop icons on or off:", name: .toggleDesktopIcons)
                    ShortcutRecorder("Eject all disks:", name: .ejectAllDisks)
                }
            case .capture:
                SettingsPage {
                    SystemScreenshotKeysToggle()
                    SettingsGap()
                    ShortcutRecorder("Capture area:", name: .captureArea)
                    ShortcutRecorder("Capture window:", name: .captureWindow)
                    ShortcutRecorder("Capture screen:", name: .captureScreen)
                    ShortcutRecorder("Capture all screens:", name: .captureAllScreens)
                }
            }
        }
    }
}

private struct BrightnessKeysToggle: View {
    @AppStorage(SettingsKey.brightnessKeysAllScreens) private var enabled = false
    @State private var trusted = BrightnessKeys.isTrusted

    var body: some View {
        Toggle("Brightness keys change every screen", isOn: $enabled)
            .labeledSettingsRow("Brightness:")
            .help("Also dims monitors macOS can't.")
            .onChange(of: enabled) { _, on in
                if on, !BrightnessKeys.isTrusted { BrightnessKeys.requestAccess() }
            }
            .pollingPermissions { trusted = BrightnessKeys.isTrusted }
        if enabled, !trusted {
            HStack(spacing: 8) {
                Label("Needs Accessibility access.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Open Settings") { BrightnessKeys.openPrivacySettings() }
            }
            .font(.callout)
        }
    }
}

private struct SystemScreenshotKeysToggle: View {
    @State private var takenOver = SystemScreenshotKeys.areTakenOver

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { takenOver },
                set: { on in
                    SystemScreenshotKeys.takeOver(on)
                    takenOver = SystemScreenshotKeys.areTakenOver
                })
        ) {
            Text("Use ⇧⌘3 and ⇧⌘4 for ModeDock")
        }
        .labeledSettingsRow("macOS keys:")
        .help("⇧⌘3 captures the screen and ⇧⌘4 an area, with ModeDock's settings.")
        .onAppear { takenOver = SystemScreenshotKeys.areTakenOver }
        SettingsNote(
            takenOver
                ? "The macOS shortcuts for these keys are off."
                : "Using ⇧⌘3 and ⇧⌘4 here turns off the matching macOS shortcuts until you switch this off.")
    }
}

private struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system

    var body: some View {
        Picker("Language:", selection: $language) {
            ForEach(AppLanguage.choices, id: \.self) { Text(verbatim: AppLanguage.name(of: $0)).tag($0) }
        }
        .fixedSize()
        .onChange(of: language) { AppLanguage.apply() }
        if AppLanguage.needsRestart {
            HStack(spacing: 8) {
                Button("Restart ModeDock") { AppLanguage.restart() }
                SettingsNote("ModeDock shows the new language after a restart.")
            }
        }
    }
}

private struct ConfigurationSection: View {
    let profiles: ProfileController
    @State private var sheet: TransferSheet?
    @State private var status: String?

    enum TransferSheet: Identifiable {
        case export
        case `import`(ConfigFile)

        var id: String {
            switch self {
            case .export: "export"
            case .import: "import"
            }
        }
    }

    var body: some View {
        Group {
            LabeledContent("Configuration:") {
                HStack {
                    Button("Export…") { sheet = .export }
                    Button("Import…", action: chooseFile)
                }
                .help("Save settings, shortcuts and profiles to a file and load them here or on another Mac.")
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            SettingsNote("Profiles include screen serial numbers.")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .export:
                ConfigGroupPicker(
                    title: String(localized: "Export Configuration"), action: "Export…",
                    available: ConfigGroup.allCases,
                    note: nil
                ) { groups in
                    self.sheet = nil
                    save(groups)
                } onCancel: {
                    self.sheet = nil
                }
            case .import(let file):
                ConfigGroupPicker(
                    title: String(localized: "Import Configuration"), action: String(localized: "Import"),
                    available: ConfigGroup.allCases.filter { file.groups[$0] != nil },
                    note:
                        String(
                            localized:
                                "Chosen parts replace your current ones. Exported from ModeDock \(file.appVersion) on \(file.exportedAt.formatted(date: .abbreviated, time: .shortened))."
                        )
                ) { groups in
                    self.sheet = nil
                    Configuration.apply(file, groups: groups, profiles: profiles)
                    status = String(localized: "Imported \(Self.list(groups)).")
                } onCancel: {
                    self.sheet = nil
                }
            }
        }
    }

    private func save(_ groups: Set<ConfigGroup>) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ModeDock Configuration.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Configuration.export(groups, profiles: profiles).write(to: url)
            status = String(localized: "Exported \(Self.list(groups)).")
        } catch {
            status = String(localized: "Couldn't export: \(error.localizedDescription)")
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            sheet = .import(try Configuration.read(Data(contentsOf: url)))
            status = nil
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func list(_ groups: Set<ConfigGroup>) -> String {
        ConfigGroup.allCases.filter(groups.contains).map(\.title).joined(separator: ", ")
    }
}

private struct ConfigGroupPicker: View {
    let title: String
    let action: String
    let available: [ConfigGroup]
    let note: String?
    let onConfirm: (Set<ConfigGroup>) -> Void
    let onCancel: () -> Void
    @State private var chosen: Set<ConfigGroup> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(available) { group in
                    Toggle(isOn: Binding(get: { chosen.contains(group) }, set: { chosen.set(group, contains: $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                            Text(group.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(chosen.count == available.count ? "Select None" : "Select All") {
                    chosen = chosen.count == available.count ? [] : Set(available)
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(action) { onConfirm(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { chosen = Set(available) }
    }
}

private struct UpdatesSection: View {
    @State private var checks = Updater.shared.checksAutomatically
    @State private var installs = Updater.shared.installsAutomatically

    var body: some View {
        Toggle("Check for updates automatically", isOn: $checks)
            .labeledSettingsRow("Updates:")
            .disabled(!Updater.isConfigured)
            .onChange(of: checks) { _, on in Updater.shared.checksAutomatically = on }
        Toggle("Download and install automatically", isOn: $installs)
            .disabled(!checks || !Updater.isConfigured)
            .onChange(of: installs) { _, on in Updater.shared.installsAutomatically = on }
        Button("Check Now") { Updater.shared.checkForUpdates() }
            .disabled(!Updater.shared.canCheck)
    }
}

private struct UsageDataSection: View {
    let screens: ScreenController
    let profiles: ProfileController
    let power: PowerController
    @State private var showingData = false
    @State private var sendResult: String?

    private var telemetry: Telemetry { .shared }

    var body: some View {
        Toggle(
            "Share anonymous usage statistics",
            isOn: Binding(get: { telemetry.isEnabled }, set: { telemetry.setEnabled($0) })
        )
        .labeledSettingsRow("Usage data:")
        Button("Show Data…") { showingData = true }
            .disabled(!telemetry.isEnabled)
            .sheet(isPresented: $showingData) {
                UsageDataView(
                    report: telemetry.preview(
                        context: .current(),
                        setup: .current(screens: screens, profiles: profiles, power: power))
                ) {
                    showingData = false
                }
            }
        SettingsNote("Which features you use, how ModeDock is set up, and your country. Nothing personal.")
        #if DEBUG
            // Debug builds only, for a local server; not translated.
            if let endpoint = telemetry.endpoint {
                HStack {
                    Button {
                        Task {
                            let sent = await telemetry.sendNow(
                                context: .current(),
                                setup: .current(screens: screens, profiles: profiles, power: power))
                            sendResult = sent ? "Sent" : "Not sent: nothing counted, or the server refused it"
                        }
                    } label: {
                        Text(verbatim: "Send Now")
                    }
                    .disabled(!telemetry.isEnabled)
                    Text(verbatim: sendResult ?? endpoint.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        #endif
    }
}

private struct UsageDataView: View {
    let report: TelemetryReport?
    let onClose: () -> Void

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return report.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Usage Data").font(.headline)
            Text("Everything ModeDock sends. The server adds your country, not your IP address.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(verbatim: json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 300)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct DebugLogSection: View {
    @AppStorage(LogFile.enabledKey) private var enabled = false

    var body: some View {
        Toggle("Write a debug log", isOn: $enabled)
            .labeledSettingsRow("Troubleshooting:")
            .help(
                "Writes a detailed log to ~/Library/Logs/ModeDock/ModeDock.log. Turn it on, repeat the problem and attach the log to your bug report. It never includes serial numbers or file contents and stays under about 4 MB."
            )
            .onChange(of: enabled) { _, on in
                if on { AppLog.app.notice("Debug logging on. \(AppLog.versionLine)") }
            }
        HStack {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
            }
            .disabled(!FileManager.default.fileExists(atPath: LogFile.url.path))
            CopyButton("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(LogFile.contents(), forType: .string)
            }
            Button("Clear") { LogFile.clear() }
        }

    }
}

/// An empty recorder means no shortcut.
struct ShortcutRecorder: View {
    let title: String
    let name: KeyboardShortcuts.Name
    var detail: String?

    init(_ title: LocalizedStringResource, name: KeyboardShortcuts.Name, detail: String? = nil) {
        self.title = String(localized: title)
        self.name = name
        self.detail = detail
    }

    var body: some View {
        // The recorder has its own ✕ to clear a shortcut.
        LabeledContent(title) {
            HStack(spacing: 8) {
                KeyboardShortcuts.Recorder(for: name)
                if let detail {
                    Text(verbatim: detail).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

private struct ScreenshotSettingsView: View {
    let screenshots: ScreenshotController
    @AppStorage(SettingsKey.screenshotDestination) private var destination = ScreenshotSettings.folder
    @AppStorage(SettingsKey.screenshotFolder) private var folder = ""
    @AppStorage(SettingsKey.screenshotFormat) private var format = ScreenshotFormat.png.rawValue
    @AppStorage(SettingsKey.screenshotPointer) private var includePointer = false
    @AppStorage(SettingsKey.screenshotPointerEverywhere) private var pointerEverywhere = false
    @AppStorage(SettingsKey.screenshotShadow) private var windowShadow = true
    @AppStorage(SettingsKey.screenshotSound) private var playSound = true
    @AppStorage(SettingsKey.screenshotDelay) private var delay = 0
    @AppStorage(SettingsKey.screenshotNotice) private var showNotice = true
    @AppStorage(SettingsKey.screenshotNoticePicture) private var showPicture = true
    @AppStorage(SettingsKey.screenshotHidesPanel) private var hidesPanel = true
    @AppStorage(SettingsKey.screenshotCombineScreens) private var combineScreens = true
    @AppStorage(SettingsKey.screenshotHDR) private var hdr = false

    private var folderURL: URL { ScreenshotSettings.folderURL(default: screenshots.defaultFolder) }

    /// "Save to the folder" or "Copy to the clipboard"; the last one on can't be turned off.
    private func destinationBinding(folder: Bool) -> Binding<Bool> {
        Binding(
            get: {
                folder
                    ? ScreenshotSettings.savesToFolder(destination) : ScreenshotSettings.copiesToClipboard(destination)
            },
            set: { on in
                let saves = folder ? on : ScreenshotSettings.savesToFolder(destination)
                let copies = folder ? ScreenshotSettings.copiesToClipboard(destination) : on
                guard saves || copies else { return }
                destination = ScreenshotSettings.value(savesToFolder: saves, copiesToClipboard: copies)
            })
    }

    @State private var tab = Tab(launchArgument: true) ?? .saving

    enum Tab: String, CaseIterable, Identifiable {
        case saving, capturing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .saving: String(localized: "Saving")
            case .capturing: String(localized: "Capturing")
            }
        }
    }

    var body: some View {
        SettingsSubTabs(tabs: Tab.allCases, title: \.title, selection: $tab) { tab in
            switch tab {
            case .saving: saving
            case .capturing: capturing
            }
        }
        .pollingPermissions { screenshots.refreshPermission() }
    }

    private var saving: some View {
        SettingsPage {
            Toggle("Folder", isOn: destinationBinding(folder: true))
                .labeledSettingsRow("Save to:")
            Toggle("Clipboard", isOn: destinationBinding(folder: false))
                .help("Both can be on. All Screens copies one image of every screen.")

            SettingsGap()

            LabeledContent("Folder:") {
                HStack {
                    Text(verbatim: (folderURL.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180, alignment: .leading)
                        .fixedSize()
                        .help(folderURL.path)
                    Button("Choose…", action: chooseFolder)
                    if !folder.isEmpty {
                        Button("Use Default") { folder = "" }
                            .help("Save where macOS saves its own screenshots.")
                    }
                }
            }
            .disabled(!ScreenshotSettings.savesToFolder(destination))
            Picker("Format:", selection: $format) {
                ForEach(ScreenshotFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            Picker("Dynamic range:", selection: $hdr) {
                Text("Standard (SDR)").tag(false)
                Text("HDR").tag(true)
            }
            .fixedSize()
            .help("HDR keeps HDR detail and wide colour, saved as HEIC. Copies include the HDR image too.")
            Picker("All Screens:", selection: $combineScreens) {
                Text("One image").tag(true)
                Text("A file per screen").tag(false)
            }
            .fixedSize()
            .help("One image lays the screens out as arranged in Displays settings.")
        }
    }

    private var capturing: some View {
        SettingsPage {
            LabeledContent("Permission:") {
                if screenshots.hasPermission {
                    Label("Screen Recording allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ScreenRecordingButtons(controller: screenshots)
                }
            }
            if !screenshots.hasPermission {
                SettingsNote("After allowing ModeDock in System Settings, you may need to reopen it.")
            }

            SettingsGap()

            Picker("Timer:", selection: $delay) {
                ForEach(ScreenshotSettings.delays, id: \.self) { seconds in
                    if seconds == 0 { Text("Off").tag(0) } else { Text("\(seconds) seconds").tag(seconds) }
                }
            }
            .fixedSize()
            .help("Applies to Screen and All Screens.")

            SettingsGap()

            Toggle("Pointer", isOn: $includePointer)
                .labeledSettingsRow("Include:")
            Toggle("Pointer in Area and Window (experimental)", isOn: $pointerEverywhere)
                .disabled(!includePointer)
                .help(
                    "macOS leaves the pointer out, so ModeDock draws it in. It may be slightly off with window shadows."
                )
            Toggle("Window shadow", isOn: $windowShadow)
            Toggle("ModeDock panel", isOn: Binding(get: { !hidesPanel }, set: { hidesPanel = !$0 }))

            SettingsGap()

            Toggle("Play sound", isOn: $playSound)
                .labeledSettingsRow("Sound:")

            SettingsGap()

            Toggle("Show a preview", isOn: $showNotice)
                .labeledSettingsRow("After capturing:")
            Toggle("Show the picture in the preview", isOn: $showPicture)
                .disabled(!showNotice)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where to save screenshots")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }
}

private struct ProfileSettingsView: View {
    let profiles: ProfileController
    let screens: ScreenController
    let modes: DisplayModeController
    @State private var selection: DisplayProfile.ID?
    @State private var deleting: DisplayProfile?
    @State private var editing: DisplayProfile.ID?
    @State private var dragging: DisplayProfile.ID?

    private var selected: DisplayProfile? { profiles.profiles.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                list
                Group {
                    if let profile = selected {
                        details(profile)
                    } else {
                        Text(
                            profiles.profiles.isEmpty
                                ? "No profiles yet. Click + to save your current setup and switch back to it in one click."
                                : "Select a profile."
                        )
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 360, height: 400, alignment: .topLeading)
            }
            .padding([.top, .horizontal], 24)

            if let error = profiles.lastError {
                ErrorLabel(error).padding(.horizontal, 24).padding(.top, 8)
            }

        }
        .padding(.bottom, 24)
        .frame(width: SettingsPage<EmptyView>.width)
        .onAppear {
            selection = selection ?? profiles.currentProfile?.id ?? profiles.profiles.first?.id
            // `-settingsSubTab edit` opens the editor, for screenshots.
            if UserDefaults.standard.string(forKey: "settingsSubTab")?.hasPrefix("edit") == true { editing = selection }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let id = editing {
                ProfileEditor(id: id, profiles: profiles, screens: screens, modes: modes) { editing = nil }
            }
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? String(localized: "the profile"))?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Delete", role: .destructive) {
                profiles.deleteWithShortcut(profile.id)
                selection = profiles.profiles.first?.id
            }
        } message: { _ in
            Text("Its shortcut is removed too. This can't be undone.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(profiles.profiles) { profile in
                    HStack(spacing: 6) {
                        dragHandle(profile)
                        Text(verbatim: profile.name).lineLimit(1)
                        if profile.autoApply { AutoTag() }
                        Spacer(minLength: 4)
                        if profiles.currentProfile?.id == profile.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .help("Current setup")
                        }
                    }
                    .tag(profile.id)
                    .opacity(dragging == profile.id ? 0.4 : 1)
                    .onDrop(
                        of: [.text],
                        delegate: ReorderDropDelegate(target: profile.id, dragging: $dragging) {
                            profiles.move($0, to: $1)
                        })
                }
            }
            .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
            .listStyle(.bordered)
            .frame(width: 170, height: 376)

            HStack(spacing: 0) {
                Button {
                    selection = profiles.capture(name: profiles.suggestedName(screens: screens)).id
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 22)
                }
                .help("Save the current setup as a new profile")
                Divider().frame(height: 14)
                Button {
                    deleting = selected
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 22)
                }
                .disabled(selected == nil)
                .help("Delete the selected profile")
                Spacer()
            }
            .buttonStyle(.borderless)
            .frame(width: 170)
            .padding(.top, 2)
        }
    }

    private func details(_ profile: DisplayProfile) -> some View {
        Form {
            LabeledContent("Name:") {
                Text(verbatim: profile.name).fontWeight(.semibold)
            }
            LabeledContent("Screens:") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(profile.screens.enumerated()), id: \.offset) { _, screen in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: screen.name)
                            Text(verbatim: screen.details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .frame(width: 240, alignment: .leading)
            }
            SettingsGap()
            LabeledContent("Also sets:") {
                Text(verbatim: profile.system.summary ?? String(localized: "Nothing else"))
                    .foregroundStyle(profile.system.isEmpty ? .secondary : .primary)
            }
            LabeledContent("Automatic:") {
                Text(profile.autoApply ? "On" : "Off").foregroundStyle(.secondary)
            }
            LabeledContent("Shortcut:") {
                Text(verbatim: profile.shortcutText ?? String(localized: "Not set")).foregroundStyle(.secondary)
            }
            SettingsGap()
            HStack {
                Button("Apply") { Task { await profiles.apply(profile) } }
                    .disabled(profiles.applying != nil)
                Button("Update from Current") { profiles.update(profile.id) }
                    .help("Replace this profile with the current setup.")
                Button("Edit…") { editing = profile.id }
            }
        }
        .formStyle(.columns)
    }

    /// Only the handle starts a drag, so clicking a row just selects it. The order is the
    /// panel's and the Next Profile shortcut's.
    private func dragHandle(_ profile: DisplayProfile) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 14, height: 18)
            .reorderHandle(profile.id, id: profile.id.uuidString, dragging: $dragging) {
                Text(verbatim: profile.name).padding(6)
            }
    }

}

private struct ProfileEditor: View {
    let id: DisplayProfile.ID
    let profiles: ProfileController
    let screens: ScreenController
    let modes: DisplayModeController
    let onDone: () -> Void
    /// Everything as it was when the editor opened, for Cancel. All profiles, because making one
    /// automatic can switch that off on another; and the shortcut, which saves as it's recorded.
    @State private var original: (profiles: [DisplayProfile], shortcut: KeyboardShortcuts.Shortcut?)?
    @State private var tab =
        UserDefaults.standard.string(forKey: "settingsSubTab") == "edit-screens" ? Tab.screens : .profile

    enum Tab: String, CaseIterable, Identifiable {
        case profile, screens

        var id: String { rawValue }

        var title: String {
            switch self {
            case .profile: String(localized: "Profile")
            case .screens: String(localized: "Screens")
            }
        }
    }

    private var profile: DisplayProfile? { profiles.profiles.first { $0.id == id } }

    enum Choice: Hashable {
        case leave, on, off

        init(_ value: Bool?) {
            self = value.map { $0 ? .on : .off } ?? .leave
        }

        var value: Bool? {
            switch self {
            case .leave: nil
            case .on: true
            case .off: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 16)

            if let profile {
                switch tab {
                case .profile: general(profile)
                case .screens: screenSettings(profile)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            original = (profiles.profiles, KeyboardShortcuts.getShortcut(for: .profile(id)))
        }
    }

    private func cancel() {
        if let original {
            profiles.replaceAll(with: original.profiles)
            KeyboardShortcuts.setShortcut(original.shortcut, for: .profile(id))
        }
        onDone()
    }

    private func general(_ profile: DisplayProfile) -> some View {
        Form {
            TextField("Name:", text: Binding(get: { profile.name }, set: { profiles.rename(id, to: $0) }))
                .frame(width: 240)

            SettingsGap()

            Toggle(
                "Apply automatically",
                isOn: Binding(get: { profile.autoApply }, set: { profiles.setAutoApply($0, for: id) })
            )
            .labeledSettingsRow("Automatic:")
            if !profile.autoApply, let other = profiles.automaticProfile(sharingScreensWith: id) {
                SettingsNote("Replaces \u{201C}\(other.name)\u{201D} for these screens.", width: 300)
            } else {
                SettingsNote(
                    "When these exact screens are connected. Only one profile per set of screens can do this.",
                    width: 300)
            }
            ShortcutRecorder("Shortcut:", name: .profile(id))
            SettingsNote("Switches to this profile from any app.", width: 300)

            SettingsGap()

            ForEach(Array(availableSettings.enumerated()), id: \.offset) { index, setting in
                LabeledContent(index == 0 ? "Also sets:" : "") {
                    HStack {
                        Text(verbatim: setting.title).frame(width: 110, alignment: .leading)
                        Picker(
                            setting.title,
                            selection: Binding(
                                get: { Choice(profile.system[setting]) },
                                set: { profiles.setSystemSetting(setting, to: $0.value, for: id) })
                        ) {
                            Text("Leave as is").tag(Choice.leave)
                            Text("On").tag(Choice.on)
                            Text("Off").tag(Choice.off)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            SettingsNote(
                "Applying the profile switches these too. Leave as is keeps whatever they are then.", width: 300)
        }
        .formStyle(.columns)
        .fixedSize()
    }

    private func screenSettings(_ profile: DisplayProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(profile.screens.enumerated()), id: \.offset) { index, screen in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: screen.name).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("Turn on:").gridColumnAlignment(.trailing)
                            Toggle(
                                "On",
                                isOn: Binding(
                                    get: { screen.isEnabled },
                                    set: { on in profiles.editScreen(screen.identity, in: id) { $0.isEnabled = on } })
                            )
                            .labelsHidden()
                        }
                        GridRow {
                            Text("Resolution:")
                            resolution(screen)
                        }
                        .disabled(!screen.isEnabled)
                        GridRow {
                            Text("Brightness:")
                            brightness(screen)
                        }
                        .disabled(!screen.isEnabled)
                    }
                }
            }
            SettingsNote(
                "The arrangement stays as saved. Update from Current takes it from your screens as they are now.",
                width: 420)
        }
        .frame(width: 460, alignment: .leading)
    }

    /// The connected screen's modes; the saved one as text when the screen isn't connected.
    @ViewBuilder
    private func resolution(_ screen: ProfileScreen) -> some View {
        if let connected = screens.screens.first(where: { $0.display.identity == screen.identity }),
            let options = modes.screens[connected.id]?.options
        {
            let all = options.flatMap(\.modes)
            Picker(
                "Resolution",
                selection: Binding(
                    get: { screen.modeKey ?? "" },
                    set: { key in profiles.editScreen(screen.identity, in: id) { $0.modeKey = key } })
            ) {
                if let key = screen.modeKey, !all.contains(where: { $0.key == key }) {
                    Text(verbatim: screen.resolution ?? key).tag(key)
                }
                ForEach(all) { mode in
                    Text(verbatim: mode.summary + (mode.isHiDPI ? "" : " (1x)")).tag(mode.key)
                }
            }
            .labelsHidden()
            .fixedSize()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: screen.resolution ?? "–")
                SettingsNote("Connect the screen to change it.", width: 260)
            }
        }
    }

    private func brightness(_ screen: ProfileScreen) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "Set brightness",
                isOn: Binding(
                    get: { screen.brightness != nil },
                    set: { on in profiles.editScreen(screen.identity, in: id) { $0.brightness = on ? 0.7 : nil } })
            )
            .labelsHidden()
            .help("Off leaves the brightness as it is when the profile is applied.")
            Slider(
                value: Binding(
                    get: { screen.brightness ?? 0.7 },
                    set: { value in profiles.editScreen(screen.identity, in: id) { $0.brightness = value } }),
                in: 0...1
            )
            .frame(width: 160)
            .disabled(screen.brightness == nil)
            Text(verbatim: screen.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var availableSettings: [ProfileSystemSettings.Setting] {
        let state = profiles.utilities?.state
        return ProfileSystemSettings.Setting.allCases.filter { setting in
            state.map { $0[keyPath: setting.stateKeyPath] != nil } ?? true
        }
    }
}

private struct AboutView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    @State private var showsAcknowledgements = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text(verbatim: "ModeDock").font(.title2.bold())
            Text("Menu-bar controls for your screens.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Text(verbatim: "Version \(Bundle.main.versionString)")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!Updater.shared.canCheck)
            }
            .padding(.top, 4)
            FlowLayout(spacing: 16) {
                AboutLink("Website", "https://modedock.app")
                AboutLink("Source", "https://github.com/ilijamt/modedock")
                if let url = issueURL { Link("Report an Issue", destination: url) }
                AboutLink("Translate", "https://crowdin.com/project/modedock")
                AboutLink("Privacy", "https://modedock.app/privacy")
            }
            .padding(.top, 12)
            Button("Acknowledgements") { showsAcknowledgements = true }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.top, 12)
            if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                Text(verbatim: copyright).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(width: SettingsPage<EmptyView>.width)
        .sheet(isPresented: $showsAcknowledgements) { AcknowledgementsView() }
    }

    // Prefills the diagnostics so reports say which Mac and screens they're about.
    private var issueURL: URL? {
        var components = URLComponents(string: "https://github.com/ilijamt/modedock/issues/new")
        let report = Diagnostics.report(screens: screens, modes: modes)
        components?.queryItems = [
            URLQueryItem(name: "body", value: "What happened?\n\n\n\nDiagnostics:\n```\n\(report)\n```\n")
        ]
        return components?.url
    }
}

private struct AboutLink: View {
    let title: LocalizedStringKey
    let url: URL?

    init(_ title: LocalizedStringKey, _ address: String) {
        self.title = title
        url = URL(string: address)
    }

    var body: some View {
        if let url { Link(title, destination: url) }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private let text =
        Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}

/// Says "Copied" for a moment after copying, so a second copy is visible too.
private struct CopyButton: View {
    let title: LocalizedStringKey
    let copy: () -> Void
    @State private var copied = false

    init(_ title: LocalizedStringKey, copy: @escaping () -> Void) {
        self.title = title
        self.copy = copy
    }

    var body: some View {
        Button(copied ? "Copied" : title) {
            copy()
            copied = true
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed =
                rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

extension View {
    /// Makes this the handle that drags `item` to a new place in its list.
    fileprivate func reorderHandle<Item: Equatable, Preview: View>(
        _ item: Item, id: String, dragging: Binding<Item?>, @ViewBuilder preview: () -> Preview
    ) -> some View {
        contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to change the order")
            .onDrag({
                dragging.wrappedValue = item
                return NSItemProvider(object: id as NSString)
            }, preview: preview)
    }
}

/// Ends a drag that's dropped outside the rows, so the dragged row doesn't stay faded.
private struct EndDragDelegate<Item: Equatable>: DropDelegate {
    @Binding var dragging: Item?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        NSCursor.closedHand.set()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct ReorderDropDelegate<Item: Equatable>: DropDelegate {
    let target: Item
    @Binding var dragging: Item?
    let move: (Item, Item) -> Void

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
