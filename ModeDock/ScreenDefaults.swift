import CoreGraphics
import Foundation
import KeyboardShortcuts
import ModeDockCore

@MainActor
enum ScreenDefaults {
    static func reset(_ display: CGDirectDisplayID, modes: DisplayModeController, brightness: BrightnessController) {
        modes.resetToDefault(display)
        brightness.resetToDefault(for: display)
    }

    static func resetAll(screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController) {
        for screen in screens.screens where screen.display.isEnabled {
            reset(screen.id, modes: modes, brightness: brightness)
        }
    }

    static func isAtDefault(
        _ display: CGDirectDisplayID, modes: DisplayModeController, brightness: BrightnessController
    ) -> Bool {
        let level = brightness.screens[display]
        let dimmed = level?.backend == .software && (level?.value ?? 1) < 1
        return modes.screens[display]?.isAtDefault ?? true && !dimmed && level?.autoBrightness != false
    }

    /// Screens and the launch-at-login item are left as they are.
    static func resetSettings(modes: DisplayModeController) {
        for key in SettingsKey.all { UserDefaults.standard.removeObject(forKey: key) }
        // Clearing the capture shortcuts alone would leave ⇧⌘3 and ⇧⌘4 off in macOS too.
        if SystemScreenshotKeys.areHeldByModeDock { SystemScreenshotKeys.takeOver(false) }
        Configuration.applyShortcuts([:], for: .shortcuts)
        modes.forgetConfirmedModes()
        AppAppearance.apply()
    }
}
