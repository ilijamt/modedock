import AppKit
import ModeDockCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: MenuPanel
    private let nativeMenu: NativeMenu
    /// Called each time the panel or menu opens, to pick up changes made elsewhere.
    private let onShow: () -> Void
    /// The panel grows downward when its content changes, so its top edge stays put.
    private var topLeft: NSPoint?
    /// Called when the panel closes, for example to move a pending prompt into its own window.
    var onClose: (() -> Void)?

    var isPanelVisible: Bool { panel.isVisible }

    init(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController, onShow: @escaping () -> Void, onOpenSettings: @escaping () -> Void
    ) {
        panel = MenuPanel()
        nativeMenu = NativeMenu(
            screens: screens, modes: modes, brightness: brightness, power: power, onOpenSettings: onOpenSettings)
        self.onShow = onShow
        super.init()

        let content = MenuView(
            screens: screens,
            modes: modes,
            brightness: brightness,
            power: power,
            onOpenSettings: { [weak self] in
                self?.close()
                onOpenSettings()
            }
        )
        panel.setContent(content, cornerRadius: 10)
        panel.delegate = self

        statusItem.autosaveName = "ModeDock"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "ModeDock")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    func toggle() {
        if !panel.isVisible { onShow() }
        if PanelStyle.current == .menu {
            close()
            showMenu()
        } else {
            panel.isVisible ? close() : show()
        }
    }

    /// Under the status item when it's on the mouse's screen; otherwise at the mouse pointer.
    private func showMenu() {
        let menu = nativeMenu.build()
        if let button = statusItem.button, let itemFrame = button.window?.frame,
            NSScreen.underMouse?.frame.contains(itemFrame) == true
        {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    func show() {
        place()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
    }

    /// Moves the open panel back under the status item, after the screens changed size.
    func reposition() {
        guard panel.isVisible else { return }
        place()
    }

    private func place() {
        let origin = origin(for: panel.frame.size)
        topLeft = NSPoint(x: origin.x, y: origin.y + panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    func close() {
        let wasVisible = panel.isVisible
        defer { if wasVisible { onClose?() } }
        panel.orderOut(nil)
        topLeft = nil
        statusItem.button?.highlight(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowDidResize(_ notification: Notification) {
        if let topLeft { panel.setFrameTopLeftPoint(topLeft) }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            close()
            let menu = nativeMenu.buildContextMenu()
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
        } else {
            toggle()
        }
    }

    /// Always on the screen under the mouse: below the status item when it is on that screen,
    /// otherwise (hidden by Bartender, or on another display's menu bar) at the top-right.
    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 4
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return .zero }
        let visible = screen.visibleFrame

        if let itemFrame = statusItem.button?.window?.frame, screen.frame.contains(itemFrame) {
            let x = min(max(itemFrame.midX - size.width / 2, visible.minX + gap), visible.maxX - size.width - gap)
            return NSPoint(x: x, y: itemFrame.minY - size.height - gap)
        }
        return NSPoint(x: visible.maxX - size.width - gap * 2, y: visible.maxY - size.height - gap)
    }
}

/// The panel under the status item; Esc closes it.
private final class MenuPanel: FloatingPanel {
    init() {
        super.init(level: .popUpMenu)
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
