import AppKit
import ModeDockCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: MenuPanel
    /// The panel grows downward when its content changes, so its top edge stays put.
    private var topLeft: NSPoint?

    init(screens: ScreenController, onOpenSettings: @escaping () -> Void) {
        panel = MenuPanel()
        super.init()

        let content = MenuView(
            screens: screens,
            onOpenSettings: { [weak self] in
                self?.close()
                onOpenSettings()
            }
        )
        panel.setContent(content)
        panel.delegate = self

        statusItem.autosaveName = "ModeDock"
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "ModeDock")
            button.target = self
            button.action = #selector(statusItemClicked)
        }
    }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        let origin = origin(for: panel.frame.size)
        topLeft = NSPoint(x: origin.x, y: origin.y + panel.frame.height)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
    }

    func close() {
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
        toggle()
    }

    /// Always on the screen under the mouse: below the status item when it is on that screen,
    /// otherwise (hidden by Bartender, or on another display's menu bar) at the top-right.
    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 4
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return .zero }
        let visible = screen.visibleFrame

        if let itemFrame = statusItem.button?.window?.frame, screen.frame.contains(itemFrame) {
            let x = min(max(itemFrame.midX - size.width / 2, visible.minX + gap), visible.maxX - size.width - gap)
            return NSPoint(x: x, y: itemFrame.minY - size.height - gap)
        }
        return NSPoint(x: visible.maxX - size.width - gap * 2, y: visible.maxY - size.height - gap)
    }
}

/// A borderless panel styled like a menu-bar popover. Non-activating, so it doesn't steal
/// focus from the frontmost app.
private final class MenuPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    func setContent(_ view: some View) {
        let root =
            view
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        let controller = NSHostingController(rootView: root)
        // Resize the panel whenever the SwiftUI content changes size (e.g. a display appears).
        controller.sizingOptions = [.preferredContentSize]
        contentViewController = controller
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
