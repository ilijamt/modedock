import AppKit
import ModeDockCore

/// Asks once whether to share usage data: on a new install, and again only when what's
/// collected changes (`Telemetry.consentVersion`).
@MainActor
enum UsageDataPrompt {
    static func askIfNeeded() {
        // Launches for screenshots open Settings and mustn't wait on a question.
        guard Telemetry.shared.shouldAsk, UserDefaults.standard.string(forKey: "settingsTab") == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Share anonymous usage data?")
        alert.informativeText = String(
            localized:
                "Counts of which features you use and how ModeDock is set up. Nothing personal. You can change this in Settings → General."
        )
        alert.addButton(withTitle: String(localized: "Share"))
        alert.addButton(withTitle: String(localized: "Don't Share")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .modalPanel
        Telemetry.shared.setEnabled(alert.runModal() == .alertFirstButtonReturn)
    }
}
