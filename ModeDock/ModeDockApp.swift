import AppKit
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let launchAtLogin = LaunchAtLogin()
    private lazy var settingsWindow = SettingsWindowController(launchAtLogin: launchAtLogin)
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController { [weak self] in
            self?.settingsWindow.show()
        }
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.menuBar?.toggle()
        }
    }
}
