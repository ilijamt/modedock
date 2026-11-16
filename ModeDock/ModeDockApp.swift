import AppKit
import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

@main
struct ModeDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The menu-bar item and the Settings window are AppKit-managed (see AppDelegate),
        // so the panel can be opened from a hotkey even when Bartender hides the icon.
        Settings { EmptyView() }
    }
}

extension AppLog {
    static let app = AppLog("app")

    static var versionLine: String {
        "ModeDock \(Bundle.main.versionString), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", initial: .init(.m, modifiers: [.control, .option, .command]))
    static let turnAllScreensOn = Self(
        "turnAllScreensOn", initial: .init(.o, modifiers: [.control, .option, .command]))

    @MainActor var shortcutText: String? { KeyboardShortcuts.getShortcut(for: self)?.description }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchAtLogin = LaunchAtLogin()
    /// Shared so screen standby and brightness never talk to a monitor at the same time.
    private let ddc = makeDDCService()
    private lazy var screens = ScreenController(ddc: ddc)
    private let modes = DisplayModeController()
    private lazy var brightness = BrightnessController(ddc: ddc)
    private let power = PowerController()
    private let utilities = UtilitiesController()
    private lazy var inputs = MonitorInputController(ddc: ddc)
    private lazy var profiles: ProfileController = {
        let profiles = ProfileController(screens: screens, modes: modes, brightness: brightness)
        profiles.utilities = utilities
        return profiles
    }()
    private let screenshots = ScreenshotCoordinator(controller: ScreenshotController())
    private lazy var shortcutActions = ShortcutActions(
        screens: screens, modes: modes, brightness: brightness, power: power, utilities: utilities, profiles: profiles)
    private let brightnessKeys = BrightnessKeys()
    private lazy var dynamicShortcuts = DynamicShortcuts(profiles: profiles, screens: screens)
    private lazy var confirmation = ModeConfirmationWindow(modes: modes)
    private lazy var settingsWindow = SettingsWindowController(
        launchAtLogin: launchAtLogin, screens: screens, modes: modes, brightness: brightness, power: power,
        profiles: profiles, screenshots: screenshots.controller)
    private var menuBar: MenuBarController?
    private var displayObserver: DisplayObserver?

    /// Both builds would grab the brightness keys and shortcuts.
    private func quitOtherBuild() {
        guard let mine = Bundle.main.bundleIdentifier else { return }
        let other = mine.hasSuffix(".dev") ? String(mine.dropLast(4)) : mine + ".dev"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: other) {
            AppLog.app.notice("Quitting \(other), which was already running")
            app.terminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherBuild()
        Telemetry.shared.record(.appLaunch)
        AppLog.app.notice("Started. \(AppLog.versionLine)")
        // After the menu bar item is up, so the question doesn't come before the app.
        Task {
            try? await Task.sleep(for: .seconds(2))
            UsageDataPrompt.askIfNeeded()
        }
        AppAppearance.apply()
        applyDDCWriteInterval()
        // Keep Awake only stops idle sleep, so a sleep that happens anyway (Sleep Mac, closing the
        // lid, Apple menu → Sleep) was asked for: that's the end of the Keep Awake session.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.power.stopKeepAwake() }
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDDCWriteInterval()
                self?.brightnessKeys.update()
            }
        }
        // Changes made in the panel are confirmed inline; the panel only needs to move back under
        // the menu bar once the screen has its new size. Anything else gets the prompt window.
        modes.onConfirmationNeeded = { [weak self] change in
            guard let self else { return }
            if let menuBar = self.menuBar, menuBar.isPanelVisible {
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    menuBar.reposition()
                }
            } else {
                self.confirmation.show(for: change)
            }
        }
        menuBar = MenuBarController(
            screens: screens, modes: modes, brightness: brightness, power: power, utilities: utilities, inputs: inputs,
            profiles: profiles, screenshots: screenshots,
            onShow: { [weak self] in
                Telemetry.shared.record(.panelOpen)
                self?.refreshBrightness()
                self?.power.refreshBattery()
                self?.utilities.refresh()
                self?.screenshots.controller.refreshPermission()
            },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )
        // `-settingsTab` launches are for screenshots.
        if UserDefaults.standard.string(forKey: "settingsTab") != nil { settingsWindow.show() }
        screenshots.closePanel = { [weak self] in self?.menuBar?.close() }
        menuBar?.onClose = { [weak self] in
            if let change = self?.modes.pending { self?.confirmation.show(for: change) }
        }
        displayObserver = DisplayObserver { [weak self] in
            guard let self else { return }
            Task {
                await self.screens.displaysChanged()
                await self.brightness.refresh(displays: self.screens.screens.map(\.display))
                await self.inputs.refresh(displays: self.screens.screens.map(\.display))
                await self.profiles.autoApplyIfNeeded()
            }
        }
        Task {
            await screens.start()
            await brightness.refresh(displays: screens.screens.map(\.display))
            await profiles.autoApplyIfNeeded()
            dynamicShortcuts.start()
        }
        // Sends the anonymous counts when allowed and a server is set. Checks hourly, so a report
        // goes out soon after `Telemetry.interval` even when the Mac slept through it.
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Also marks days the Mac stays on with ModeDock running but unused.
                Telemetry.shared.markActive()
                await Telemetry.shared.sendIfDue(
                    context: .current(),
                    setup: .current(screens: self.screens, profiles: self.profiles, power: self.power))
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            Telemetry.shared.recordShortcut(KeyboardShortcuts.Name.togglePanel.rawValue)
            self?.menuBar?.toggle()
        }
        for mode in ScreenshotMode.allCases {
            guard let name = mode.shortcut else { continue }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
                Telemetry.shared.recordShortcut(name.rawValue)
                self?.screenshots.take(mode)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .turnAllScreensOn) { [weak self] in
            guard let self else { return }
            Telemetry.shared.recordShortcut(KeyboardShortcuts.Name.turnAllScreensOn.rawValue)
            Telemetry.shared.record(.screensAllOn)
            Task { await self.screens.restoreAll() }
        }
        shortcutActions.start()
        brightnessKeys.onPress = { [weak self] direction in
            Telemetry.shared.record(.brightnessKeys)
            self?.shortcutActions.changeBrightness(by: Double(direction) * ShortcutActions.brightnessStep)
        }
        brightnessKeys.update()
    }

    private func applyDDCWriteInterval() {
        let milliseconds = UserDefaults.standard.object(forKey: SettingsKey.ddcWriteInterval) as? Int
        brightness.ddcWriteInterval = .milliseconds(milliseconds ?? SettingsKey.ddcWriteIntervalDefault)
    }

    private func refreshBrightness() {
        Task {
            let displays = screens.screens.map(\.display)
            await brightness.refresh(displays: displays)
            await inputs.refresh(displays: displays)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        brightness.resetSoftwareDimming()
        Task {
            await screens.restoreAll()
            displayObserver?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
