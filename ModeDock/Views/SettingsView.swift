import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

/// The Settings tabs, in order. Each becomes a toolbar item in the Settings window.
enum SettingsTab: String, CaseIterable {
    case general, menu, displays, profiles, screenshots, shortcuts, about

    var title: String {
        switch self {
        case .general: "General"
        case .menu: "Menu"
        case .displays: "Displays"
        case .profiles: "Profiles"
        case .screenshots: "Capture"
        case .shortcuts: "Shortcuts"
        case .about: "About"
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
        case .about: "info.circle"
        }
    }

    /// Fixed sizes keep the window from jumping between tabs by a few points.
    var height: CGFloat {
        switch self {
        case .general: 340
        case .menu: 560
        case .displays: 500
        case .profiles: 460
        case .screenshots: 600
        case .shortcuts: 520
        case .about: 250
        }
    }

    @MainActor @ViewBuilder
    func content(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController, profiles: ProfileController, screenshots: ScreenshotController
    ) -> some View {
        switch self {
        case .general: GeneralSettingsView(modes: modes, power: power)
        case .menu: MenuSettingsView()
        case .displays: DisplaySettingsView(screens: screens, modes: modes, brightness: brightness)
        case .profiles: ProfileSettingsView(profiles: profiles, screens: screens)
        case .screenshots: ScreenshotSettingsView(screenshots: screenshots)
        case .shortcuts: ShortcutSettingsView(screens: screens)
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

            DebugLogSection()

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
    @State private var expanded: Set<MenuSection> = []
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue
    @AppStorage(PanelLayout.key) private var panelLayout = PanelLayout.tabs.rawValue

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
                Picker("Layout", selection: $panelLayout) {
                    ForEach(PanelLayout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(panelStyle == PanelStyle.menu.rawValue)
            } footer: {
                Text((PanelLayout(rawValue: panelLayout) ?? .tabs).summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // A grouped Form doesn't support onMove on macOS, so rows are dragged and dropped instead.
                ForEach(layout.order) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section)
                        if expanded.contains(section) {
                            sectionDetails(section)
                                .padding(.leading, 52)
                                .disabled(layout.hidden.contains(section))
                        }
                    }
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
            } header: {
                Text("Sections")
            } footer: {
                Text(
                    "Turn sections on or off, and open one to choose what it shows. Drag sections, or right-click one, to change their order."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A drop anywhere else in the window ends the drag, so the dragged row doesn't stay faded.
        .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
    }

    private func sectionHeader(_ section: MenuSection) -> some View {
        let items = PanelItem.allCases.filter { $0.section == section }
        let shown = items.filter { !PanelItem.hidden(in: hiddenItems).contains($0) }.count
        let isOpen = expanded.contains(section)
        return HStack {
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
            .onDrag {
                dragging = section
                return NSItemProvider(object: section.rawValue as NSString)
            } preview: {
                Label(section.title, systemImage: section.systemImage).padding(6)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.set(section, contains: !isOpen) }
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: "\(shown) of \(items.count) shown")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the options" : "Choose what this section shows")

            Toggle("Show \(section.title)", isOn: visibility(of: section))
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private func sectionDetails(_ section: MenuSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(PanelItem.allCases.filter { $0.section == section }) { item in
                    ItemChip(title: item.title, isOn: itemVisibility(item))
                }
            }
            if panelLayout == PanelLayout.list.rawValue {
                Picker("Starts", selection: expansion(of: section)) {
                    Text("Open").tag(true)
                    Text("Collapsed").tag(false)
                }
                .fixedSize()
                .help("Whether the section starts open or collapsed in the panel")
            }
        }
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
    let screens: ScreenController
    @AppStorage(SettingsKey.profileCycleScope) private var profileCycleScope = ProfileCycleScope.connected.rawValue

    var body: some View {
        Form {
            Section {
                ShortcutRecorder("Open ModeDock", name: .togglePanel)
            } footer: {
                Text("Leave a shortcut empty to turn it off. Click ✕ to clear one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                BrightnessKeysToggle()
                ShortcutRecorder("Brightness up", name: .brightnessUp)
                ShortcutRecorder("Brightness down", name: .brightnessDown)
                ShortcutRecorder("Sleep screens", name: .sleepScreens)
                ShortcutRecorder("Mirror on or off", name: .toggleMirror)
                ShortcutRecorder("Turn all screens on", name: .turnAllScreensOn)
                ForEach(screens.screens.filter { !$0.display.identity.isPlaceholder }) { screen in
                    ShortcutRecorder(
                        "Turn \(screen.display.name) on or off", name: .toggleScreen(screen.display.identity))
                }
            } header: {
                Text("Screens")
            } footer: {
                Text(
                    "Brightness changes every screen that's on, including monitors the brightness keys can't reach. At least one screen always stays on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ShortcutRecorder("Next profile", name: .nextProfile)
                Picker("Cycle through", selection: $profileCycleScope) {
                    ForEach(ProfileCycleScope.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Profiles")
            } footer: {
                Text(
                    "Shows the profiles and moves to the next one each time you press it; the highlighted one is applied when you stop. \"Connected screens\" only includes profiles saved with exactly the screens plugged in now. Each profile's own shortcut is set in Profiles."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Power and Utilities") {
                ShortcutRecorder("Keep Awake on or off", name: .toggleKeepAwake)
                ShortcutRecorder("Dark Mode on or off", name: .toggleDarkMode)
                ShortcutRecorder("Night Shift on or off", name: .toggleNightShift)
                ShortcutRecorder("True Tone on or off", name: .toggleTrueTone)
                ShortcutRecorder("Desktop icons on or off", name: .toggleDesktopIcons)
                ShortcutRecorder("Eject all disks", name: .ejectAllDisks)
            }

            Section {
                SystemScreenshotKeysToggle()
                ShortcutRecorder("Capture area", name: .captureArea)
                ShortcutRecorder("Capture window", name: .captureWindow)
                ShortcutRecorder("Capture screen", name: .captureScreen)
                ShortcutRecorder("Capture all screens", name: .captureAllScreens)
            } header: {
                Text("Screenshots")
            } footer: {
                Text(
                    "macOS uses ⇧⌘3 and ⇧⌘4 for its own screenshots. Using them for ModeDock turns those macOS shortcuts off, and their ⌃ clipboard versions; turning it off again gives them back."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// "Brightness keys change every screen", with the Accessibility permission it needs.
private struct BrightnessKeysToggle: View {
    @AppStorage(SettingsKey.brightnessKeysAllScreens) private var enabled = false
    @State private var trusted = BrightnessKeys.isTrusted

    var body: some View {
        Toggle(isOn: $enabled) {
            Text("Brightness keys change every screen")
            Text("The keyboard's brightness keys also dim monitors that macOS can't.")
        }
        .onChange(of: enabled) { _, on in
            if on, !BrightnessKeys.isTrusted { BrightnessKeys.requestAccess() }
        }
        .task {
            // Notice when access is granted in System Settings.
            while !Task.isCancelled {
                trusted = BrightnessKeys.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if enabled, !trusted {
            HStack {
                Label(
                    "ModeDock needs Accessibility access to use the brightness keys.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Spacer()
                Button("Open Settings") { BrightnessKeys.openPrivacySettings() }
            }
            .font(.callout)
        }
    }
}

/// "Use ⇧⌘3 and ⇧⌘4 for ModeDock", which turns the macOS screenshot shortcuts off or back on.
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
            if takenOver {
                Text("⇧⌘3 captures the screen and ⇧⌘4 an area with ModeDock. The macOS shortcuts for them are off.")
            }
        }
        .help("⇧⌘3 captures the screen and ⇧⌘4 an area, with ModeDock's settings.")
        .onAppear { takenOver = SystemScreenshotKeys.areTakenOver }
    }
}

/// Debug logging for bug reports: the switch, and the file it writes.
private struct DebugLogSection: View {
    @AppStorage(LogFile.enabledKey) private var enabled = false
    @State private var copied = false

    var body: some View {
        Section {
            Toggle("Debug logging", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on { AppLog.app.notice("Debug logging on. \(AppLog.versionLine)") }
                }
            LabeledContent("Log file") {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: LogFile.url.path))
                    Button(copied ? "Copied" : "Copy Log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LogFile.contents(), forType: .string)
                        copied = true
                    }
                    Button("Clear") {
                        LogFile.clear()
                        copied = false
                    }
                }
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text(
                "Writes what ModeDock does to ~/Library/Logs/ModeDock/ModeDock.log, including details macOS doesn't keep. Turn it on, repeat the problem, then attach the log to your bug report. It never contains serial numbers or file contents, and stays under about 4 MB."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// A shortcut recorder with a button that clears it. An empty recorder means no shortcut.
struct ShortcutRecorder: View {
    let title: String
    let name: KeyboardShortcuts.Name
    @State private var isSet = false

    /// KeyboardShortcuts posts this for every change, but doesn't make the name public.
    private static let shortcutChanged = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    init(_ title: String, name: KeyboardShortcuts.Name) {
        self.title = title
        self.name = name
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                KeyboardShortcuts.Recorder(for: name) { isSet = $0 != nil }
                Button {
                    // setShortcut(nil) rather than reset, which would bring a default back.
                    KeyboardShortcuts.setShortcut(nil, for: name)
                    isSet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!isSet)
                .opacity(isSet ? 1 : 0.3)
                .help("Clear this shortcut")
            }
        }
        .onAppear { isSet = KeyboardShortcuts.getShortcut(for: name) != nil }
        // Also when a shortcut is set from code, such as when taking over ⇧⌘3 and ⇧⌘4.
        .onReceive(NotificationCenter.default.publisher(for: Self.shortcutChanged)) { _ in
            isSet = KeyboardShortcuts.getShortcut(for: name) != nil
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

    var body: some View {
        Form {
            Section {
                Toggle("Save to the folder", isOn: destinationBinding(folder: true))
                Toggle("Copy to the clipboard", isOn: destinationBinding(folder: false))
                LabeledContent("Folder") {
                    HStack {
                        Text(verbatim: (folderURL.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(folderURL.path)
                        Button("Choose…", action: chooseFolder)
                        if !folder.isEmpty {
                            Button("Use Default") { folder = "" }
                                .help("Save where macOS saves its own screenshots.")
                        }
                    }
                }
                .disabled(!ScreenshotSettings.savesToFolder(destination))
                Picker("Format", selection: $format) {
                    ForEach(ScreenshotFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("All Screens saves", selection: $combineScreens) {
                    Text("One image").tag(true)
                    Text("A file per screen").tag(false)
                }
                .help("One image lays the screens out the way they're arranged in System Settings → Displays.")
            } footer: {
                Text(
                    "By default, screenshots go where macOS saves its own. With both on, each one is saved and copied. All Screens always copies one image of every screen, laid out like your displays."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include the pointer", isOn: $includePointer)
                Toggle(isOn: $pointerEverywhere) {
                    Text("Also in Area and Window captures (experimental)")
                    Text(
                        "macOS leaves the pointer out of these, so ModeDock draws it where it was when the capture started, if that's inside what you captured. It can be a little off, especially with window shadows."
                    )
                }
                .disabled(!includePointer)
                Picker("Timer", selection: $delay) {
                    ForEach(ScreenshotSettings.delays, id: \.self) { seconds in
                        if seconds == 0 { Text("Off").tag(0) } else { Text("\(seconds) seconds").tag(seconds) }
                    }
                }
                Toggle("Window shadow", isOn: $windowShadow)
                Toggle("Play sound", isOn: $playSound)
                Toggle("Hide ModeDock while capturing", isOn: $hidesPanel)
                    .help("Off to include the ModeDock panel in the screenshot.")
                Toggle("Show a preview after capturing", isOn: $showNotice)
                Toggle("Show the picture in the preview", isOn: $showPicture)
                    .disabled(!showNotice)
            } footer: {
                Text(
                    "The timer applies to Screen and All Screens captures, and so does the pointer unless the experimental option is on. The shadow applies to window captures."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Screen Recording") {
                    if screenshots.hasPermission {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        ScreenRecordingButtons(controller: screenshots)
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text(
                    "macOS asks before any app can capture the screen. After allowing ModeDock in System Settings, "
                        + "you may need to quit and reopen it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Picks up a permission granted in System Settings while this window is open.
        .task {
            while !Task.isCancelled {
                screenshots.refreshPermission()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folderURL
        panel.prompt = "Choose"
        panel.message = "Choose where to save screenshots"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url.path
    }
}

private struct ProfileSettingsView: View {
    let profiles: ProfileController
    let screens: ScreenController
    @State private var deleting: DisplayProfile?
    @State private var expanded: Set<DisplayProfile.ID> = []
    @State private var dragging: DisplayProfile.ID?

    var body: some View {
        Form {
            if profiles.profiles.isEmpty {
                Section {
                    Text("No profiles yet. Save the current setup to switch back to it later in one click.")
                        .foregroundStyle(.secondary)
                }
            }

            // A grouped Form doesn't support onMove on macOS, so profiles are dragged by their title row.
            ForEach(profiles.profiles) { profile in
                Section {
                    titleRow(profile)
                    if expanded.contains(profile.id) {
                        details(profile)
                    }
                }
                .opacity(dragging == profile.id ? 0.4 : 1)
            }

            Section {
                Button("Save Current Setup") { profiles.capture(name: profiles.suggestedName(screens: screens)) }
                if let error = profiles.lastError {
                    ErrorLabel(error)
                }
            } footer: {
                Text(
                    "A profile remembers which screens are on, their resolutions, arrangement, mirroring and "
                        + "brightness. Screens that aren't connected are skipped when it's applied. Drag profiles to "
                        + "change their order, which is the panel's and the Next Profile shortcut's."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDrop(of: [.text], delegate: EndDragDelegate(dragging: $dragging))
        .confirmationDialog(
            "Delete \(deleting?.name ?? "the profile")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Delete", role: .destructive) { profiles.deleteWithShortcut(profile.id) }
        } message: { _ in
            Text("Its shortcut is removed too. This can't be undone.")
        }
    }

    /// Drag handle, name and what's set, and the chevron that shows the rest.
    private func titleRow(_ profile: DisplayProfile) -> some View {
        let isOpen = expanded.contains(profile.id)
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Text(verbatim: profile.name).fontWeight(.medium).lineLimit(1)
                if profiles.currentProfile?.id == profile.id { tag("Current") }
                if profile.autoApply { tag("Automatic") }
                Spacer()
                if let shortcut = profile.shortcutText {
                    Text(verbatim: shortcut).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to change the order")
            .onDrag {
                dragging = profile.id
                return NSItemProvider(object: profile.id.uuidString as NSString)
            } preview: {
                Label(profile.name, systemImage: "rectangle.3.group").padding(6)
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.set(profile.id, contains: !isOpen) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide the details" : "Show the details")
        }
        .onDrop(
            of: [.text],
            delegate: ReorderDropDelegate(target: profile.id, dragging: $dragging) { profiles.move($0, to: $1) }
        )
        .contextMenu {
            Button("Move Up") { profiles.move(profile.id, by: -1) }
                .disabled(profiles.profiles.first?.id == profile.id)
            Button("Move Down") { profiles.move(profile.id, by: 1) }
                .disabled(profiles.profiles.last?.id == profile.id)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.primary.opacity(0.08), in: Capsule())
    }

    @ViewBuilder
    private func details(_ profile: DisplayProfile) -> some View {
        TextField("Name", text: name(of: profile))
        LabeledContent("Screens") {
            ProfileScreenLines(profile: profile)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)
        }
        Toggle(isOn: autoApply(of: profile)) {
            Text("Apply automatically")
            if !profile.autoApply, let other = profiles.automaticProfile(sharingScreensWith: profile.id) {
                Text(verbatim: "Replaces \u{201C}\(other.name)\u{201D}, which applies for these screens now.")
            } else {
                Text("When these screens are plugged in or out. One profile per set of screens.")
            }
        }
        ShortcutRecorder("Shortcut", name: .profile(profile.id))
        HStack {
            Button("Apply") { Task { await profiles.apply(profile) } }
                .disabled(profiles.applying != nil)
            Button("Update from Current") { profiles.update(profile.id) }
                .help("Replace this profile's screens, resolutions, arrangement and brightness with the current ones.")
            Spacer()
            Button("Delete…", role: .destructive) { deleting = profile }
        }
    }

    private func name(of profile: DisplayProfile) -> Binding<String> {
        Binding(get: { profile.name }, set: { profiles.rename(profile.id, to: $0) })
    }

    private func autoApply(of profile: DisplayProfile) -> Binding<Bool> {
        Binding(get: { profile.autoApply }, set: { profiles.setAutoApply($0, for: profile.id) })
    }
}

private struct AboutView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    @State private var copied = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
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
/// An on/off chip for one item of a section, tinted when the item is shown.
private struct ItemChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: isOn ? "checkmark" : "plus")
                .font(.callout)
                .foregroundStyle(isOn ? .white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.08)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Shown. Click to hide it." : "Hidden. Click to show it.")
    }
}

/// Lays out views left to right, wrapping onto new lines when the width runs out.
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

/// Reorders rows while dragging, as the pointer passes over them, and shows the move cursor
/// rather than the copy one.
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
