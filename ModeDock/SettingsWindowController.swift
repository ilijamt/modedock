import AppKit
import ModeDockCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let launchAtLogin: LaunchAtLogin
    private var window: NSWindow?

    init(launchAtLogin: LaunchAtLogin) {
        self.launchAtLogin = launchAtLogin
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Agent apps aren't frontmost, so the window would open behind other apps.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView().environment(launchAtLogin))
        let window = NSWindow(contentViewController: controller)
        window.title = "ModeDock Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
