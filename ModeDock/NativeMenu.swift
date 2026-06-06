import AppKit
import DisplayKit
import ModeDockCore

/// The "Native menu" panel style: a regular NSMenu, rebuilt each time it opens.
@MainActor
final class NativeMenu {
    private let screens: ScreenController
    private let modes: DisplayModeController
    private let onOpenSettings: () -> Void

    init(screens: ScreenController, modes: DisplayModeController, onOpenSettings: @escaping () -> Void) {
        self.screens = screens
        self.modes = modes
        self.onOpenSettings = onOpenSettings
    }

    func build() -> NSMenu {
        let defaults = UserDefaults.standard
        modes.refresh(
            displays: screens.screens.map(\.display),
            showAllModes: defaults.bool(forKey: SettingsKey.showAllModes))

        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: "Screens"))
        for screen in screens.screens {
            menu.addItem(screenItem(screen, showStandby: defaults.bool(forKey: SettingsKey.showDDCStandby)))
        }

        menu.addItem(.separator())
        if modes.canMirror || modes.isMirroring {
            let mirror = ActionItem("Mirror Screens") { [modes] in modes.setMirroring(!modes.isMirroring) }
            mirror.state = modes.isMirroring ? .on : .off
            menu.addItem(mirror)
        }
        menu.addItem(ActionItem("Sleep All Screens") { [screens] in screens.sleepAllDisplays() })
        let allOn = ActionItem("Turn All On") { [screens] in Task { await screens.restoreAll() } }
        allOn.keyEquivalent = "o"
        allOn.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(allOn)

        if let error = screens.lastError ?? modes.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            ActionItem("Copy Diagnostics") { [screens, modes] in Diagnostics.copy(screens: screens, modes: modes) })
        let settings = ActionItem("Settings…", action: onOpenSettings)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ActionItem("Quit ModeDock") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    private func screenItem(_ screen: ScreenController.Screen, showStandby: Bool) -> NSMenuItem {
        let display = screen.display
        let screenModes = modes.screens[screen.id]
        var title = display.name
        if screenModes?.isMain == true && display.isEnabled { title += " (Main)" }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(
            systemSymbolName: display.isBuiltin ? "laptopcomputer" : "display", accessibilityDescription: nil)
        if #available(macOS 15.0, *) {
            item.subtitle = subtitle(screen, screenModes)
        }

        let submenu = NSMenu()
        if display.isEnabled, let screenModes {
            submenu.addItem(.sectionHeader(title: "Resolution"))
            for option in screenModes.options {
                let isCurrent = option.modes.contains { $0.id == screenModes.current?.id }
                if option.modes.count == 1, let mode = option.modes.first {
                    let modeItem = ActionItem(label(option, in: screenModes)) { [modes] in
                        modes.select(mode, for: screen.id)
                    }
                    modeItem.state = isCurrent ? .on : .off
                    submenu.addItem(modeItem)
                } else {
                    let sizeItem = NSMenuItem(title: label(option, in: screenModes), action: nil, keyEquivalent: "")
                    sizeItem.state = isCurrent ? .on : .off
                    let rates = NSMenu()
                    for mode in option.modes {
                        let rateItem = ActionItem("\(Int(mode.refreshRate.rounded())) Hz") { [modes] in
                            modes.select(mode, for: screen.id)
                        }
                        rateItem.state = mode.id == screenModes.current?.id ? .on : .off
                        rates.addItem(rateItem)
                    }
                    sizeItem.submenu = rates
                    submenu.addItem(sizeItem)
                }
            }
            submenu.addItem(.separator())
            if !screenModes.isMain {
                submenu.addItem(ActionItem("Use as Main Screen") { [modes] in modes.makeMain(screen.id) })
            }
        }
        if showStandby && screen.supportsDDC && display.isEnabled {
            submenu.addItem(
                ActionItem(screen.isInStandby ? "Wake" : "Standby") { [screens] in
                    Task { await screens.setStandby(!screen.isInStandby, screen: screen.id) }
                })
        }
        let power = ActionItem(display.isEnabled ? "Turn Off" : "Turn On") { [screens] in
            screens.setEnabled(!display.isEnabled, screen: screen.id)
        }
        power.isEnabled = !display.isEnabled || screen.canDisable
        submenu.addItem(power)
        item.submenu = submenu
        return item
    }

    private func subtitle(_ screen: ScreenController.Screen, _ screenModes: DisplayModeController.ScreenModes?)
        -> String
    {
        guard screen.display.isEnabled else { return "Off" }
        if screen.isInStandby { return "Standby" }
        guard let current = screenModes?.current else { return "" }
        let size = "\(current.width) × \(current.height)"
        return current.refreshRate > 0 ? "\(size) · \(Int(current.refreshRate.rounded())) Hz" : size
    }

    private func label(_ option: ResolutionOption, in screenModes: DisplayModeController.ScreenModes) -> String {
        var text = "\(option.width) × \(option.height)"
        let hasHiDPIVersion = screenModes.options.contains {
            $0.isHiDPI && $0.width == option.width && $0.height == option.height
        }
        if !option.isHiDPI && hasHiDPIVersion { text += " (low resolution)" }
        if option.isNative { text += " · Native" }
        return text
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
