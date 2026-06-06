import AppKit
import ModeDockCore
import SwiftUI

/// The "Keep this resolution?" prompt, centered on the screen that changed.
@MainActor
final class ModeConfirmationWindow {
    private let modes: DisplayModeController
    private var panel: PromptPanel?

    init(modes: DisplayModeController) {
        self.modes = modes
    }

    func show(for change: DisplayModeController.PendingChange) {
        close()
        let panel = PromptPanel()
        let view = ConfirmationView(modes: modes, change: change) { [weak self] in self?.close() }
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        self.panel = panel

        // The screen's frame changes with the new mode, so wait for macOS to settle first.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let panel = self.panel else { return }
            let screen = NSScreen.screens.first { $0.displayID == change.display } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(
                    NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
            }
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ConfirmationView: View {
    let modes: DisplayModeController
    let change: DisplayModeController.PendingChange
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Keep this resolution?").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(change.deadline.timeIntervalSince(context.date).rounded(.up)))
                // Plain string: Text would format the numbers for the locale ("1.920").
                Text(verbatim: "Going back to \(change.previous.width) × \(change.previous.height) in \(remaining) s.")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Button("Revert") { modes.revert() }
                    .keyboardShortcut(.cancelAction)
                Button("Keep") { modes.confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: modes.pending) { if modes.pending != change { onClose() } }
    }
}

/// Borderless, non-activating and never hidden on deactivate: macOS may refuse to activate a
/// background menu-bar app, and a regular panel would then hide itself straight away.
private final class PromptPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hidesOnDeactivate = false
        level = .modalPanel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
