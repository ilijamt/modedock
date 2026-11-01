import AppKit
import ModeDockCore
import SwiftUI

/// The Settings window, with icon tabs in the toolbar like other Mac apps' settings. Each tab
/// sizes the window to its content.
@MainActor
final class SettingsWindowController {
    private let launchAtLogin: LaunchAtLogin
    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let power: PowerController
    private let profiles: ProfileController
    private let screenshots: ScreenshotController
    private var window: NSWindow?

    init(
        launchAtLogin: LaunchAtLogin, screens: ScreenController, modes: DisplayModeController,
        brightness: BrightnessController, power: PowerController, profiles: ProfileController,
        screenshots: ScreenshotController
    ) {
        self.launchAtLogin = launchAtLogin
        self.screens = screens
        self.modes = modes
        self.brightness = brightness
        self.power = power
        self.profiles = profiles
        self.screenshots = screenshots
    }

    func show() {
        Telemetry.shared.record(.settingsOpened)
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
            let view = tab.content(
                screens: screens, modes: modes, brightness: brightness, power: power, profiles: profiles,
                screenshots: screenshots
            )
            .environment(launchAtLogin)
            let controller = NSHostingController(rootView: view)
            // The tab controller sizes the window to the selected tab's preferred content size.
            controller.sizingOptions = [.preferredContentSize]
            controller.title = tab.title
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        // `-settingsTab capture` on the command line opens on that tab, for screenshots.
        if let name = UserDefaults.standard.string(forKey: "settingsTab"),
            let index = SettingsTab.allCases.firstIndex(where: { "\($0)" == name })
        {
            tabs.selectedTabViewItemIndex = index
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
