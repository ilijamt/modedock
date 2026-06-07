import CoreGraphics
import Foundation
import KeyboardShortcuts
import ModeDockCore

/// "Reset to Defaults": the default resolution and refresh rate, no software dimming, and
/// automatic brightness on where the screen has a light sensor.
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

    /// Resets every ModeDock setting: appearance, panel style, menu sections, display options,
    /// shortcuts and remembered resolutions. Screens aren't touched, and launch at login is a
    /// system login item, so it's left as it is.
    static func resetSettings(modes: DisplayModeController) {
        for key in SettingsKey.all { UserDefaults.standard.removeObject(forKey: key) }
        KeyboardShortcuts.reset(.togglePanel, .turnAllScreensOn)
        modes.forgetConfirmedModes()
        AppAppearance.apply()
    }
}
