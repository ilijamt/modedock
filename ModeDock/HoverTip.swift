import AppKit
import SwiftUI

extension View {
    /// A tooltip by the pointer after a short hover. The panel belongs to an app that's rarely
    /// active, where macOS shows its own tooltips late or not at all.
    func tip(_ text: LocalizedStringResource) -> some View {
        modifier(HoverTipModifier(text: String(localized: text)))
    }

    /// For text that's already localized, or isn't text to translate.
    func tip(verbatim text: String) -> some View {
        modifier(HoverTipModifier(text: text))
    }
}

private struct HoverTipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { HoverTip.shared.schedule(text) } else { HoverTip.shared.hide() }
            }
            .onDisappear { HoverTip.shared.hide() }
            .accessibilityHint(text)
    }
}

/// The one tooltip window, shown next to the pointer.
@MainActor
final class HoverTip {
    static let shared = HoverTip()
    private static let delay = Duration.milliseconds(450)

    private let panel: FloatingPanel = {
        let panel = FloatingPanel(level: .popUpMenu)
        panel.ignoresMouseEvents = true
        return panel
    }()
    private var task: Task<Void, Never>?

    func schedule(_ text: String) {
        task?.cancel()
        panel.orderOut(nil)
        guard !text.isEmpty else { return }
        task = Task {
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            show(text)
        }
    }

    func hide() {
        task?.cancel()
        task = nil
        panel.orderOut(nil)
    }

    private func show(_ text: String) {
        // Sized once and set by hand; letting SwiftUI resize the window looped in layout before.
        // Measured at the widest it may be, so short text stays on one line and long text wraps.
        let label = Text(verbatim: text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        let maxWidth: CGFloat = 276
        let measured = NSHostingController(rootView: label)
            .sizeThatFits(in: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(ceil(measured.width), maxWidth), height: ceil(measured.height))
        let content = NSHostingView(
            rootView:
                label
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)))
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.setContentSize(size)

        // Below and to the right of the pointer, kept on the screen.
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - 24 - size.height)
        if let frame = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, frame.minX + 4), frame.maxX - size.width - 4)
            if origin.y < frame.minY + 4 { origin.y = mouse.y + 16 }
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}
