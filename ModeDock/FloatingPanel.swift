import AppKit
import SwiftUI

/// Non-activating, so it doesn't steal focus from the frontmost app.
class FloatingPanel: NSPanel {
    init(level: NSWindow.Level) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.level = level
        isOpaque = false
        // ModeDock is rarely the active app while its panels are open, and tooltips are hidden
        // for inactive apps unless the window opts in.
        allowsToolTipsWhenApplicationIsInactive = true
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    func setContent(_ view: some View, cornerRadius: CGFloat) {
        let root =
            view
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in
                // Not resized by SwiftUI: it redraws the window in the middle of AppKit's layout
                // pass, and glass drawn there crashes on macOS 26. So it happens right after.
                DispatchQueue.main.async { self?.fit(size) }
            }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        contentView = host
        fit(host.fittingSize)
    }

    /// Keeps the top edge in place, so panels grow downwards.
    private func fit(_ size: CGSize) {
        guard size != frame.size, size.width > 0, size.height > 0 else { return }
        let top = frame.maxY
        setFrame(NSRect(origin: NSPoint(x: frame.minX, y: top - size.height), size: size), display: true)
    }

    func center(on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.midY - self.frame.height / 2))
    }
}

/// Borderless, non-activating and never hidden on deactivate: macOS may refuse to activate a
/// background menu-bar app, and a regular panel would then hide itself straight away.
final class PromptPanel: FloatingPanel {
    init() {
        super.init(level: .modalPanel)
        hidesOnDeactivate = false
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}
