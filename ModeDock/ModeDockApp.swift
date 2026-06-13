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

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.m, modifiers: [.control, .option, .command]))
    static let turnAllScreensOn = Self(
        "turnAllScreensOn", default: .init(.o, modifiers: [.control, .option, .command]))
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
    private lazy var confirmation = ModeConfirmationWindow(modes: modes)
    private lazy var settingsWindow = SettingsWindowController(
        launchAtLogin: launchAtLogin, screens: screens, modes: modes, brightness: brightness, power: power)
    private var menuBar: MenuBarController?
    private var displayObserver: DisplayObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            MainActor.assumeIsolated { self?.applyDDCWriteInterval() }
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
            screens: screens, modes: modes, brightness: brightness, power: power,
            onShow: { [weak self] in
                self?.refreshBrightness()
                self?.power.refreshBattery()
            },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )
        menuBar?.onClose = { [weak self] in
            // Never leave a change waiting for confirmation without a visible prompt.
            if let change = self?.modes.pending { self?.confirmation.show(for: change) }
        }
        displayObserver = DisplayObserver { [weak self] in
            guard let self else { return }
            Task {
                await self.screens.displaysChanged()
                await self.brightness.refresh(displays: self.screens.screens.map(\.display))
            }
        }
        Task {
            await screens.start()
            await brightness.refresh(displays: screens.screens.map(\.display))
        }

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.menuBar?.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .turnAllScreensOn) { [weak self] in
            guard let self else { return }
            Task { await self.screens.restoreAll() }
        }
    }

    private func applyDDCWriteInterval() {
        let milliseconds = UserDefaults.standard.object(forKey: SettingsKey.ddcWriteInterval) as? Int
        brightness.ddcWriteInterval = .milliseconds(milliseconds ?? SettingsKey.ddcWriteIntervalDefault)
    }

    private func refreshBrightness() {
        Task { await brightness.refresh(displays: screens.screens.map(\.display)) }
    }

    /// Never leave a screen off, in standby or dimmed after quitting.
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
