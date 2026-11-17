import AppKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

extension Notification.Name {
    static let openSetupAssistant = Notification.Name("openSetupAssistant")
}

/// The pages of the setup assistant. Each records the setup revision that added it, so after an
/// upgrade people are asked about the new pages only.
enum SetupStep: String, CaseIterable, Identifiable {
    case welcome, look, sections, keyboard, capture, permissions, startup, done

    var id: String { rawValue }

    /// 0 for pages shown on every run. A new page gets `SetupAssistant.revision` bumped by one.
    var revision: Int {
        switch self {
        case .welcome, .done: 0
        case .look, .sections, .keyboard, .capture, .permissions, .startup: 1
        }
    }
}

@MainActor
final class SetupAssistant: NSObject, NSWindowDelegate {
    /// Bump when a page is added, so people who upgrade are asked about it.
    static let revision = 1
    private static let revisionKey = "setupRevision"

    private let launchAtLogin: LaunchAtLogin
    private let screenshots: ScreenshotController
    private let openPanel: () -> Void
    private var window: NSWindow?
    /// Called once the window closes, finished or not.
    var onClose: (() -> Void)?

    init(launchAtLogin: LaunchAtLogin, screenshots: ScreenshotController, openPanel: @escaping () -> Void) {
        self.launchAtLogin = launchAtLogin
        self.screenshots = screenshots
        self.openPanel = openPanel
    }

    private static var seenRevision: Int { UserDefaults.standard.integer(forKey: revisionKey) }

    /// Opens on a new install, asks after an upgrade that added pages, and otherwise returns false.
    func showIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard Self.seenRevision < Self.revision else { return false }
        // Someone who already answered the usage data question used ModeDock before the assistant existed.
        let isNewInstall = defaults.object(forKey: Self.revisionKey) == nil && Telemetry.shared.shouldAsk
        if isNewInstall {
            show(since: 0)
            return true
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "ModeDock has new options")
        alert.informativeText = String(
            localized: "Set them up in a few clicks? You can do it later from Settings → General → Setup Assistant.")
        alert.addButton(withTitle: String(localized: "Set Up…"))
        alert.addButton(withTitle: String(localized: "Not Now")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        if alert.runModal() == .alertFirstButtonReturn {
            show(since: Self.seenRevision)
            return true
        }
        markSeen()
        return false
    }

    /// Shows the pages added after `since`; 0 shows them all.
    func show(since: Int = 0) {
        window?.close()
        let steps = SetupStep.allCases.filter { $0.revision == 0 || $0.revision > since }
        let view = SetupView(
            steps: steps, isUpdate: since > 0, screenshots: screenshots,
            onOpenPanel: { [weak self] in
                self?.window?.close()
                self?.openPanel()
            },
            onClose: { [weak self] in self?.window?.close() }
        )
        .environment(launchAtLogin)
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "ModeDock Setup")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        markSeen()
        window = nil
        onClose?()
    }

    private func markSeen() {
        UserDefaults.standard.set(Self.revision, forKey: Self.revisionKey)
    }
}

// MARK: - Pages

private struct SetupView: View {
    let steps: [SetupStep]
    let isUpdate: Bool
    let screenshots: ScreenshotController
    let onOpenPanel: () -> Void
    let onClose: () -> Void
    /// `-setupStep look` on the command line opens on that page, for screenshots.
    @State private var current = UserDefaults.standard.string(forKey: "setupStep").flatMap(SetupStep.init) ?? .welcome
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(SettingsKey.brightnessKeysAllScreens) private var brightnessKeys = false

    /// The screenshot and permission pages only appear when something picked needs them.
    private var visibleSteps: [SetupStep] {
        let capturing = !Set<MenuSection>(CommaSeparated.decode(hiddenSections)).contains(.screenshots)
        return steps.filter {
            switch $0 {
            case .capture: capturing
            case .permissions: !neededPermissions.isEmpty
            default: true
            }
        }
    }

    private var neededPermissions: [SetupPermission] {
        let hidden = Set<MenuSection>(CommaSeparated.decode(hiddenSections))
        var needed: [SetupPermission] = []
        if brightnessKeys { needed.append(.accessibility) }
        if !hidden.contains(.screenshots) { needed.append(.screenRecording) }
        if !hidden.contains(.utilities), !PanelItem.hidden(in: hiddenItems).contains(.emptyTrash) {
            needed.append(.automation)
        }
        return needed
    }

    private var index: Int { visibleSteps.firstIndex(of: current) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch current {
                case .welcome: WelcomePage(isUpdate: isUpdate)
                case .look: LookPage()
                case .sections: SectionsPage()
                case .keyboard: KeyboardPage()
                case .capture: CapturePage(screenshots: screenshots)
                case .permissions: PermissionsPage(permissions: neededPermissions, screenshots: screenshots)
                case .startup: StartupPage()
                case .done: DonePage(onOpenPanel: onOpenPanel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 28)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 580, height: 520)
    }

    private var footer: some View {
        HStack {
            if current != .welcome, current != .done {
                Text("Step \(index) of \(visibleSteps.count - 2)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if index > 0, current != .done {
                Button("Back") { move(by: -1) }
            }
            if current == .done {
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            } else {
                Button(current == .welcome ? "Get Started" : "Continue") { move(by: 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func move(by offset: Int) {
        let steps = visibleSteps
        let next = min(max(index + offset, 0), steps.count - 1)
        withAnimation(.snappy(duration: 0.2)) { current = steps[next] }
    }
}

private struct PageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }
}

/// A large, clickable choice with an icon and one line explaining it.
private struct ChoiceCard: View {
    let systemImage: String
    let title: String
    let detail: String
    let isSelected: Bool
    var isCheckbox = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 34)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.body.weight(.medium))
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: indicator)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var indicator: String {
        if isCheckbox {
            isSelected ? "checkmark.square.fill" : "square"
        } else {
            isSelected ? "checkmark.circle.fill" : "circle"
        }
    }
}

private struct WelcomePage: View {
    let isUpdate: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            if isUpdate {
                PageHeader(
                    title: "ModeDock has new options",
                    subtitle: "This update added a few things you can set up. It only takes a minute.")
            } else {
                PageHeader(
                    title: "Welcome to ModeDock",
                    subtitle:
                        "ModeDock lives in the menu bar at the top of your screen. It puts your screens, brightness, screenshots and everyday Mac switches one click away."
                )
                Text("A few quick questions and you're done. You can change everything later in Settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 24)
    }
}

private struct LookPage: View {
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue
    @AppStorage(PanelLayout.key) private var panelLayout = PanelLayout.tabs.rawValue

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(
                title: "How should ModeDock look?",
                subtitle: "This is what opens when you click ModeDock in the menu bar.")
            ForEach(PanelStyle.allCases) { style in
                ChoiceCard(
                    systemImage: style.systemImage, title: style.title, detail: style.summary,
                    isSelected: panelStyle == style.rawValue
                ) { panelStyle = style.rawValue }
            }
            if panelStyle != PanelStyle.menu.rawValue {
                Picker("Show sections:", selection: $panelLayout) {
                    ForEach(PanelLayout.allCases) { Text($0.summary).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension PanelStyle {
    fileprivate var systemImage: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .rows: "list.bullet.rectangle"
        case .menu: "filemenu.and.selection"
        }
    }
}

private struct SectionsPage: View {
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""

    private var hidden: Set<MenuSection> { Set(CommaSeparated.decode(hiddenSections)) }

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(
                title: "What would you like to use?",
                subtitle: "Pick the parts you want. The others stay out of your way.")
            ForEach(MenuSection.allCases) { section in
                let shown = !hidden.contains(section)
                ChoiceCard(
                    systemImage: section.systemImage, title: section.title, detail: section.setupSummary,
                    isSelected: shown, isCheckbox: true
                ) {
                    var hidden = hidden
                    hidden.set(section, contains: shown)
                    // Keep at least one, or the panel would be empty.
                    guard hidden.count < MenuSection.allCases.count else { return }
                    hiddenSections = CommaSeparated.encode(MenuSection.allCases.filter(hidden.contains))
                }
            }
        }
    }
}

extension MenuSection {
    fileprivate var setupSummary: String {
        switch self {
        case .screens: String(localized: "Change resolution and brightness, or turn screens off.")
        case .profiles: String(localized: "Save your screen setup and switch back to it in one click.")
        case .power: String(localized: "Keep the Mac awake, put it to sleep or lock it.")
        case .utilities: String(localized: "Dark Mode, Night Shift, hide the Dock and more.")
        case .screenshots: String(localized: "Take a picture of an area, a window or the whole screen.")
        }
    }
}

private struct KeyboardPage: View {
    @AppStorage(SettingsKey.brightnessKeysAllScreens) private var brightnessKeys = false

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(
                title: "Keyboard",
                subtitle: "Shortcuts are optional. You can always click ModeDock in the menu bar instead.")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open ModeDock with").font(.body.weight(.medium))
                    Text("Click the box and press the keys you want, or keep this one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyboardShortcuts.Recorder(for: .togglePanel)
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5))
            .padding(.bottom, 6)

            ChoiceCard(
                systemImage: "sun.max",
                title: String(localized: "Brightness keys work on every screen"),
                detail: String(localized: "The brightness keys on your keyboard also dim external monitors."),
                isSelected: brightnessKeys, isCheckbox: true
            ) { brightnessKeys.toggle() }
        }
    }
}

private struct CapturePage: View {
    let screenshots: ScreenshotController
    @AppStorage(SettingsKey.screenshotDestination) private var destination = ScreenshotSettings.folder
    @AppStorage(SettingsKey.screenshotFolder) private var folder = ""
    @State private var takenOver = SystemScreenshotKeys.areTakenOver

    private var folderURL: URL { folder.isEmpty ? screenshots.defaultFolder : URL(fileURLWithPath: folder) }

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(
                title: "Screenshots",
                subtitle: "Choose where your screenshots go and which keys take them.")
            destinationCard(
                ScreenshotSettings.folder, systemImage: "folder",
                title: String(localized: "Save as a file"),
                detail: String(localized: "Kept in a folder, like the macOS screenshots."))
            destinationCard(
                ScreenshotSettings.clipboard, systemImage: "doc.on.clipboard",
                title: String(localized: "Copy, ready to paste"),
                detail: String(localized: "Paste it straight into a message or document. Nothing is saved."))
            destinationCard(
                ScreenshotSettings.both, systemImage: "square.on.square",
                title: String(localized: "Both"),
                detail: String(localized: "Save a file and copy it too."))
            if ScreenshotSettings.savesToFolder(destination) {
                HStack {
                    Text("Folder:")
                    Text(verbatim: (folderURL.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(folderURL.path)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                .padding(.horizontal, 4)
            }

            ChoiceCard(
                systemImage: "keyboard",
                title: String(localized: "Use ⇧⌘3 and ⇧⌘4 for ModeDock"),
                detail: String(
                    localized:
                        "The usual screenshot keys use the choice above instead of the macOS settings. Turn this off later to get the macOS ones back."
                ),
                isSelected: takenOver, isCheckbox: true
            ) {
                SystemScreenshotKeys.takeOver(!takenOver)
                takenOver = SystemScreenshotKeys.areTakenOver
            }
            .padding(.top, 8)
        }
        .onAppear { takenOver = SystemScreenshotKeys.areTakenOver }
    }

    private func destinationCard(_ value: String, systemImage: String, title: String, detail: String) -> some View {
        ChoiceCard(systemImage: systemImage, title: title, detail: detail, isSelected: destination == value) {
            destination = value
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

enum SetupPermission: CaseIterable {
    case accessibility, screenRecording, automation
}

private struct PermissionsPage: View {
    let permissions: [SetupPermission]
    let screenshots: ScreenshotController
    @State private var accessibility = BrightnessKeys.isTrusted
    @State private var automation = PermissionStatus.notAsked

    var body: some View {
        VStack(spacing: 10) {
            PageHeader(
                title: "Allow access",
                subtitle:
                    "macOS asks you before ModeDock can do some things. Click Allow, then turn ModeDock on in the window that opens."
            )
            ForEach(permissions, id: \.self) { permission in
                row(permission)
            }
        }
        // System Settings doesn't tell apps when a permission changes.
        .task {
            while !Task.isCancelled {
                accessibility = BrightnessKeys.isTrusted
                screenshots.refreshPermission()
                automation = await Task.detached { FinderAutomation.status() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func row(_ permission: SetupPermission) -> some View {
        switch permission {
        case .accessibility:
            PermissionRow(
                systemImage: "sun.max", title: String(localized: "Brightness keys"),
                detail: String(localized: "Lets the brightness keys reach every screen."),
                isAllowed: accessibility
            ) { BrightnessKeys.requestAccess() }
        case .screenRecording:
            PermissionRow(
                systemImage: "camera.viewfinder", title: String(localized: "Screenshots"),
                detail: String(
                    localized:
                        "macOS calls this Screen Recording. ModeDock only takes pictures and never records audio."),
                isAllowed: screenshots.hasPermission
            ) { screenshots.requestPermission() }
        case .automation:
            PermissionRow(
                systemImage: "trash", title: String(localized: "Empty Trash"),
                detail: String(localized: "Lets ModeDock ask Finder to empty the Trash."),
                isAllowed: automation == .allowed
            ) {
                if automation == .denied {
                    FinderAutomation.openPrivacySettings()
                } else {
                    Task { automation = await Task.detached { FinderAutomation.status(askIfNeeded: true) }.value }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isAllowed: Bool
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body.weight(.medium))
                Text(verbatim: detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isAllowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: allow)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5))
    }
}

private struct StartupPage: View {
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @State private var autoUpdate = Updater.shared.checksAutomatically && Updater.shared.installsAutomatically
    /// Nothing is picked until the person answers.
    @State private var sharing: Bool? = Telemetry.shared.shouldAsk ? nil : Telemetry.shared.isEnabled

    var body: some View {
        VStack(spacing: 8) {
            PageHeader(title: "A few last things", subtitle: "Recommended settings are a good start.")
            ChoiceCard(
                systemImage: "power",
                title: String(localized: "Start ModeDock when you log in"),
                detail: String(localized: "Recommended, so it's always there."),
                isSelected: launchAtLogin.isEnabled, isCheckbox: true
            ) { launchAtLogin.setEnabled(!launchAtLogin.isEnabled) }
            if let error = launchAtLogin.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if Updater.isConfigured {
                ChoiceCard(
                    systemImage: "arrow.down.circle",
                    title: String(localized: "Keep ModeDock up to date"),
                    detail: String(localized: "Installs updates by itself. Recommended."),
                    isSelected: autoUpdate, isCheckbox: true
                ) {
                    autoUpdate.toggle()
                    Updater.shared.checksAutomatically = autoUpdate
                    Updater.shared.installsAutomatically = autoUpdate
                }
            }

            Text("Share anonymous usage data?")
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
            Text(
                "Counts of which features you use, how ModeDock is set up, and your country. Nothing personal. It helps decide what to improve."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                choice(String(localized: "Share"), on: true)
                choice(String(localized: "Don't Share"), on: false)
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private func choice(_ title: String, on: Bool) -> some View {
        ChoiceCard(
            systemImage: on ? "chart.bar" : "hand.raised", title: title, detail: "",
            isSelected: sharing == on
        ) {
            sharing = on
            Telemetry.shared.setEnabled(on)
        }
    }
}

private struct DonePage: View {
    let onOpenPanel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            PageHeader(
                title: "You're all set",
                subtitle: doneText)
            Button("Open ModeDock Now", action: onOpenPanel)
                .controlSize(.large)
            Text("Run this again any time from Settings → General → Setup Assistant.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .padding(.top, 24)
    }

    private var doneText: LocalizedStringKey {
        if let shortcut = KeyboardShortcuts.Name.togglePanel.shortcutText {
            "Click the ModeDock icon in the menu bar at the top of your screen, or press \(shortcut)."
        } else {
            "Click the ModeDock icon in the menu bar at the top of your screen."
        }
    }
}
