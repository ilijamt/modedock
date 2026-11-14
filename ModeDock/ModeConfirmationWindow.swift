import AppKit
import ModeDockCore
import SwiftUI

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
        panel.setContent(
            ConfirmationView(modes: modes, change: change) { [weak self] in self?.close() }, cornerRadius: 14)
        self.panel = panel

        // The screen's frame changes with the new mode, so wait for macOS to settle first.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let panel = self.panel else { return }
            panel.center(on: NSScreen.screens.first { $0.displayID == change.display } ?? NSScreen.main)
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
            RevertCountdown(change: change)
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
