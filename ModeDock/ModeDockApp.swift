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
    private let screens = ScreenController()
    private lazy var settingsWindow = SettingsWindowController(launchAtLogin: launchAtLogin)
    private var menuBar: MenuBarController?
    private var displayObserver: DisplayObserver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(screens: screens) { [weak self] in
            self?.settingsWindow.show()
        }
        displayObserver = DisplayObserver { [weak self] in
            guard let self else { return }
            Task { await self.screens.displaysChanged() }
        }
        Task { await screens.start() }

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.menuBar?.toggle()
        }
        KeyboardShortcuts.onKeyUp(for: .turnAllScreensOn) { [weak self] in
            guard let self else { return }
            Task { await self.screens.restoreAll() }
        }
    }

    /// Never leave a screen off or in standby after quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await screens.restoreAll()
            displayObserver?.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
