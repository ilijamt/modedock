import AppKit
import ModeDockCore
import SwiftUI

/// The Settings window, with icon tabs in the toolbar like other Mac apps' settings.
@MainActor
final class SettingsWindowController {
    private let launchAtLogin: LaunchAtLogin
    private let screens: ScreenController
    private let modes: DisplayModeController
    private var window: NSWindow?

    init(launchAtLogin: LaunchAtLogin, screens: ScreenController, modes: DisplayModeController) {
        self.launchAtLogin = launchAtLogin
        self.screens = screens
        self.modes = modes
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Agent apps aren't frontmost, and macOS may refuse to activate one, so also bring the
        // window forward on its own; otherwise it can open behind other apps.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let view = tab.content(screens: screens, modes: modes)
                .environment(launchAtLogin)
                .frame(width: 480, height: tab.height)
            let controller = NSHostingController(rootView: view)
            // The tab controller sizes the window to the selected tab's preferred content size.
            controller.sizingOptions = [.preferredContentSize]
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
