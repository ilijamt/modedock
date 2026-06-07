import AppKit
import DisplayKit
import ModeDockCore

/// The "Native menu" panel style: a regular NSMenu, rebuilt each time it opens.
@MainActor
final class NativeMenu {
    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let onOpenSettings: () -> Void

    init(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        onOpenSettings: @escaping () -> Void
    ) {
        self.screens = screens
        self.modes = modes
        self.brightness = brightness
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
        menu.addItem(.sectionHeader(title: "Screens"))
        for screen in screens.screens {
            menu.addItem(screenItem(screen, showStandby: defaults.bool(forKey: SettingsKey.showDDCStandby)))
            if screen.display.isEnabled, let level = brightness.screens[screen.id] {
                let item = NSMenuItem()
                item.view = BrightnessMenuView(display: screen.display, level: level, brightness: brightness)
                menu.addItem(item)
            }
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
        addAppItems(to: menu)
        return menu
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
        item.image = NSImage(
            systemSymbolName: display.isBuiltin ? "laptopcomputer" : "display", accessibilityDescription: nil)
        if #available(macOS 15.0, *) {
            item.subtitle = subtitle(screen, screenModes)
        }

        let submenu = NSMenu()
        // Otherwise AppKit enables every item with a target and ignores `isEnabled` below.
        submenu.autoenablesItems = false
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

        let minimum = level.backend == .software ? BrightnessController.softwareMinimum : 0
        let slider = NSSlider(
            value: level.value, minValue: minimum, maxValue: 1, target: self, action: #selector(changed(_:)))
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
