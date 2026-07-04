import AppKit
import DisplayKit
import KeyboardShortcuts
import ModeDockCore

/// The "Native menu" panel style: a regular NSMenu, rebuilt each time it opens.
@MainActor
final class NativeMenu {
    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let power: PowerController
    private let utilities: UtilitiesController
    private let inputs: MonitorInputController
    private let profiles: ProfileController
    private let screenshots: ScreenshotCoordinator
    private let onOpenSettings: () -> Void

    init(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController, utilities: UtilitiesController, inputs: MonitorInputController,
        profiles: ProfileController, screenshots: ScreenshotCoordinator, onOpenSettings: @escaping () -> Void
    ) {
        self.screens = screens
        self.modes = modes
        self.brightness = brightness
        self.power = power
        self.utilities = utilities
        self.inputs = inputs
        self.profiles = profiles
        self.screenshots = screenshots
        self.onOpenSettings = onOpenSettings
    }

    func build() -> NSMenu {
        let defaults = UserDefaults.standard
        modes.refresh(
            displays: screens.screens.map(\.display),
            showAllModes: defaults.bool(forKey: SettingsKey.showAllModes))

        let menu = NSMenu()
        // Pop-up menus don't inherit NSApp.appearance, so ModeDock's Appearance setting is applied here.
        menu.appearance = NSApp.appearance
        let layout = MenuLayout(
            order: defaults.string(forKey: SettingsKey.sectionOrder) ?? "",
            hidden: defaults.string(forKey: SettingsKey.hiddenSections) ?? "", collapsed: "")
        let hidden = PanelItem.hiddenNow
        for (index, section) in layout.visible.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            switch section {
            case .screens: addScreenItems(to: menu, hidden: hidden)
            case .profiles: addProfileItems(to: menu, hidden: hidden)
            case .power: addPowerItems(to: menu, hidden: hidden)
            case .utilities: addUtilityItems(to: menu, hidden: hidden)
            case .screenshots: addScreenshotItems(to: menu, hidden: hidden)
            }
        }

        menu.addItem(.separator())
        addAppItems(to: menu)
        return menu
    }

    private func addScreenItems(to menu: NSMenu, hidden: Set<PanelItem>) {
        menu.addItem(.sectionHeader(title: "Screens"))
        for screen in screens.screens {
            menu.addItem(
                screenItem(screen, showStandby: UserDefaults.standard.bool(forKey: SettingsKey.showDDCStandby)))
            if screen.display.isEnabled, !hidden.contains(.brightness), let level = brightness.screens[screen.id] {
                let item = NSMenuItem()
                item.view = BrightnessMenuView(display: screen.display, level: level, brightness: brightness)
                menu.addItem(item)
            }
        }

        if !hidden.isSuperset(of: [.mirror, .sleepScreens, .allOn]) { menu.addItem(.separator()) }
        if !hidden.contains(.mirror) && (modes.canMirror || modes.isMirroring) {
            let mirror = ActionItem("Mirror Screens") { [modes] in modes.setMirroring(!modes.isMirroring) }
            mirror.state = modes.isMirroring ? .on : .off
            menu.addItem(mirror)
        }
        if !hidden.contains(.sleepScreens) {
            menu.addItem(ActionItem("Sleep All Screens") { [screens] in screens.sleepAllDisplays() })
        }
        if !hidden.contains(.allOn) {
            let allOn = ActionItem("Turn All On") { [screens] in Task { await screens.restoreAll() } }
            // Not setShortcut(for:): that keeps an observer per item, and the menu is rebuilt on every open.
            allOn.setShortcut(KeyboardShortcuts.getShortcut(for: .turnAllScreensOn))
            menu.addItem(allOn)
        }

        addError(screens.lastError ?? modes.lastError, to: menu)
    }

    private func addProfileItems(to menu: NSMenu, hidden: Set<PanelItem>) {
        menu.addItem(.sectionHeader(title: "Profiles"))
        if profiles.profiles.isEmpty {
            let empty = NSMenuItem(title: "No Saved Profiles", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for profile in profiles.profiles {
            let item = ActionItem(profile.name) { [profiles] in Task { await profiles.apply(profile) } }
            item.state = profiles.isActive(profile) ? .on : .off
            item.toolTip = profile.screenList
            if #available(macOS 15.0, *) { item.subtitle = profile.summary }
            // Not setShortcut(for:): that keeps an observer per item, and the menu is rebuilt on every open.
            item.setShortcut(KeyboardShortcuts.getShortcut(for: .profile(profile.id)))
            menu.addItem(item)
        }
        if !hidden.contains(.saveProfile) {
            menu.addItem(
                ActionItem("Save Current Setup…") { [profiles, screens] in
                    Self.saveProfile(profiles, screens: screens)
                })
        }
        addError(profiles.lastError, to: menu)
    }

    /// The menu has closed by now, so a regular alert asks for the name.
    private static func saveProfile(_ profiles: ProfileController, screens: ScreenController) {
        let suggested = profiles.suggestedName(screens: screens)
        let alert = NSAlert()
        alert.messageText = "Save Current Setup"
        alert.informativeText = "Saves the screens that are on, their resolutions, arrangement and brightness."
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles.capture(name: name.isEmpty ? suggested : name)
    }

    private func inputItem(_ available: MonitorInputController.Inputs, screen: ScreenController.Screen) -> NSMenuItem {
        let item = NSMenuItem(title: "Input", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for input in available.available {
            let choice = ActionItem(available.name(of: input)) { [inputs] in
                guard input != available.current, Self.confirmInputSwitch(available.name(of: input)) else { return }
                Task { await inputs.select(input, for: screen.id) }
            }
            choice.state = input == available.current ? .on : .off
            choice.toolTip = String(format: "Input source 0x%02X", input)
            menu.addItem(choice)
        }
        item.submenu = menu
        return item
    }

    private static func confirmInputSwitch(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Switch to \(name)?"
        alert.informativeText = MonitorInputController.switchWarning
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func addUtilityItems(to menu: NSMenu, hidden: Set<PanelItem>) {
        utilities.refresh()
        menu.addItem(.sectionHeader(title: "Utilities"))
        for toggle in UtilityToggle.visible(utilities, hidden: hidden) {
            let item = ActionItem(toggle.title) { toggle.set(!toggle.isOn) }
            item.image = NSImage(systemSymbolName: toggle.systemImage, accessibilityDescription: nil)
            item.state = toggle.isOn ? .on : .off
            item.toolTip = toggle.help
            menu.addItem(item)
        }
        if !hidden.contains(.emptyTrash) {
            let trash = ActionItem("Empty Trash…") { [utilities] in Self.confirmEmptyTrash(utilities) }
            trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(trash)
        }
        if !hidden.contains(.ejectDisks) {
            let eject = ActionItem(utilities.ejectTitle) { [utilities] in Task { await utilities.ejectAll() } }
            eject.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)
            eject.isEnabled = utilities.state.ejectableVolumes > 0 && !utilities.isEjecting
            menu.addItem(eject)
        }
        addError(utilities.lastError, to: menu)
    }

    /// The menu has closed by now, so a regular alert is used; ModeDock is activated so it shows
    /// in front.
    private static func confirmEmptyTrash(_ utilities: UtilitiesController) {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "The items in the Trash will be deleted. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        if alert.runModal() == .alertFirstButtonReturn { utilities.emptyTrash() }
    }

    private func addScreenshotItems(to menu: NSMenu, hidden: Set<PanelItem>) {
        let controller = screenshots.controller
        controller.refreshPermission()
        menu.addItem(.sectionHeader(title: "Screenshots"))
        if !controller.hasPermission {
            let allow = ActionItem("Allow Screen Recording…") { [controller] in Self.askForScreenRecording(controller) }
            allow.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
            allow.toolTip = "ModeDock needs Screen Recording permission to take screenshots."
            menu.addItem(allow)
        }
        let toClipboard = ScreenshotSettings.savesToClipboard
        for mode in screenshots.visibleModes(hidden: hidden) {
            let item = ActionItem(mode.menuTitle) { [screenshots] in screenshots.take(mode) }
            item.image = NSImage(systemSymbolName: mode.systemImage, accessibilityDescription: nil)
            item.toolTip = mode.help(savesToClipboard: toClipboard)
            item.isEnabled = screenshots.isEnabled(mode, savesToClipboard: toClipboard)
            // Not setShortcut(for:): that keeps an observer per item, and the menu is rebuilt on every open.
            if let shortcut = mode.shortcut { item.setShortcut(KeyboardShortcuts.getShortcut(for: shortcut)) }
            menu.addItem(item)
        }
        addError(controller.lastError, to: menu)
    }

    /// The menu has closed by now, so a regular alert explains the permission first.
    private static func askForScreenRecording(_ controller: ScreenshotController) {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording?"
        alert.informativeText =
            "ModeDock needs Screen Recording permission to take screenshots. Allow it when macOS asks, or turn "
            + "on ModeDock in System Settings → Privacy & Security → Screen Recording. You may need to quit and "
            + "reopen ModeDock afterwards."
        alert.addButton(withTitle: "Allow…")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        switch alert.runModal() {
        case .alertFirstButtonReturn: controller.requestPermission()
        case .alertSecondButtonReturn: ScreenshotSettings.openPrivacySettings()
        default: break
        }
    }

    private func addPowerItems(to menu: NSMenu, hidden: Set<PanelItem>) {
        menu.addItem(.sectionHeader(title: "Power"))
        if !hidden.contains(.keepAwake) { menu.addItem(keepAwakeItem()) }

        if !hidden.contains(.battery) {
            power.refreshBattery()
            if let battery = power.battery {
                let item = NSMenuItem(title: "Battery: \(battery.summary)", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: battery.systemImage, accessibilityDescription: nil)
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        if !hidden.contains(.sleepMac) {
            let sleep = ActionItem("Sleep Mac") { [power] in power.sleep() }
            sleep.image = NSImage(systemSymbolName: "powersleep", accessibilityDescription: nil)
            menu.addItem(sleep)
        }
        if !hidden.contains(.lock) {
            let lock = ActionItem("Lock Screen") { [power] in power.lockScreen() }
            lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
            menu.addItem(lock)
        }

        addError(power.lastError, to: menu)
    }

    private func addError(_ message: String?, to menu: NSMenu) {
        guard let message else { return }
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        item.isEnabled = false
        menu.addItem(item)
    }

    private func keepAwakeItem() -> NSMenuItem {
        let keepAwake = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        keepAwake.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
        keepAwake.state = power.isKeepingAwake ? .on : .off
        if #available(macOS 15.0, *) {
            keepAwake.subtitle =
                switch power.keepAwake?.endsAt {
                case .some(let endsAt): "On until \(endsAt.formatted(date: .omitted, time: .shortened))"
                case .none: power.isKeepingAwake ? "On until turned off" : "Off"
                }
        }
        let durations = NSMenu()
        if power.isKeepingAwake {
            durations.addItem(ActionItem("Turn Off") { [power] in power.stopKeepAwake() })
            durations.addItem(.separator())
        }
        for minutes in PowerController.presets {
            let item = ActionItem(PowerController.title(minutes: minutes)) { [power] in
                KeepAwakeSettings.start(minutes: minutes, power: power)
            }
            item.state = power.isKeepingAwake && power.keepAwake?.minutes == minutes ? .on : .off
            durations.addItem(item)
        }
        let custom = ActionItem("Custom…") { [power] in CustomKeepAwakeWindow.shared.show(power: power) }
        if let label = KeepAwakeSettings.customLabel(power.keepAwake?.minutes) {
            custom.title = "\(label)…"
            custom.state = .on
        }
        durations.addItem(custom)
        durations.addItem(.separator())
        let screensOn = ActionItem("Keep Screens On") { [power] in
            KeepAwakeSettings.setKeepScreensOn(!KeepAwakeSettings.keepScreensOn, power: power)
        }
        screensOn.state = KeepAwakeSettings.keepScreensOn ? .on : .off
        durations.addItem(screensOn)
        keepAwake.submenu = durations
        return keepAwake
    }

    /// The right-click menu of the status item.
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.appearance = NSApp.appearance
        addAppItems(to: menu)
        return menu
    }

    private func addAppItems(to menu: NSMenu) {
        menu.addItem(
            ActionItem("Copy Diagnostics") { [screens, modes] in Diagnostics.copy(screens: screens, modes: modes) })
        let settings = ActionItem("Settings…", action: onOpenSettings)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = ActionItem("Quit ModeDock") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func screenItem(_ screen: ScreenController.Screen, showStandby: Bool) -> NSMenuItem {
        let display = screen.display
        let screenModes = modes.screens[screen.id]
        var title = display.name
        if screenModes?.isMain == true && display.isEnabled { title += " (Main)" }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: display.systemImage, accessibilityDescription: nil)
        if #available(macOS 15.0, *) {
            item.subtitle = subtitle(screen, screenModes)
        }

        let submenu = NSMenu()
        // Otherwise AppKit enables every item with a target and ignores `isEnabled` below.
        submenu.autoenablesItems = false
        if display.isEnabled, let screenModes {
            submenu.addItem(.sectionHeader(title: "Resolution"))
            for option in screenModes.options {
                let isCurrent = screenModes.isCurrent(option)
                if option.modes.count == 1, let mode = option.modes.first {
                    let modeItem = ActionItem(screenModes.label(for: option)) { [modes] in
                        modes.select(mode, for: screen.id)
                    }
                    modeItem.state = isCurrent ? .on : .off
                    submenu.addItem(modeItem)
                } else {
                    let sizeItem = NSMenuItem(title: screenModes.label(for: option), action: nil, keyEquivalent: "")
                    sizeItem.state = isCurrent ? .on : .off
                    let rates = NSMenu()
                    for mode in option.modes {
                        let rateItem = ActionItem(mode.refreshRateText) { [modes] in
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
            if let auto = brightness.screens[screen.id]?.autoBrightness {
                let autoItem = ActionItem("Automatic Brightness") { [brightness] in
                    brightness.setAutoBrightness(!auto, for: screen.id)
                }
                autoItem.state = auto ? .on : .off
                submenu.addItem(autoItem)
            }
            if !screenModes.isMain {
                submenu.addItem(ActionItem("Use as Main Screen") { [modes] in modes.makeMain(screen.id) })
            }
            if let available = inputs.screens[screen.id] {
                submenu.addItem(inputItem(available, screen: screen))
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
        return screenModes?.current?.summary ?? ""
    }
}

/// A labelled slider row, like the volume slider in the Sound menu.
private final class BrightnessMenuView: NSView {
    private let display: Display
    private let brightness: BrightnessController
    private var slider: NSSlider!
    private var autoButton: NSButton?
    private var timer: Timer?

    init(display: Display, level: BrightnessController.ScreenBrightness, brightness: BrightnessController) {
        self.display = display
        self.brightness = brightness
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 26))

        let slider = NSSlider(
            value: level.value, minValue: level.minimum, maxValue: 1, target: self, action: #selector(changed(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.toolTip = "Brightness of \(display.name)"
        self.slider = slider

        // Sun icons on both ends, like the display slider in Control Center.
        var views: [NSView] = [Self.icon("sun.min"), slider, Self.icon("sun.max")]
        if let auto = level.autoBrightness {
            // A checkbox: the "on" look of a push button is too faint to read in a menu.
            let button = NSButton(checkboxWithTitle: "Auto", target: self, action: #selector(toggleAuto(_:)))
            button.controlSize = .small
            button.state = auto ? .on : .off
            button.toolTip = "Adjust brightness automatically to the light around you."
            views.append(button)
            autoButton = button
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Lines up with the screen name above it, after the icon.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Follows changes made by automatic brightness or the brightness keys while the menu is open.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        // Menus track events in their own run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sync() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        brightness.syncSystemBrightness()
        guard let level = brightness.screens[display.id] else { return }
        slider.doubleValue = level.value
        if let auto = level.autoBrightness { autoButton?.state = auto ? .on : .off }
    }

    private static func icon(_ name: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    @objc private func changed(_ sender: NSSlider) {
        brightness.set(sender.doubleValue, for: display.id)
    }

    @objc private func toggleAuto(_ sender: NSButton) {
        brightness.setAutoBrightness(sender.state == .on, for: display.id)
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
