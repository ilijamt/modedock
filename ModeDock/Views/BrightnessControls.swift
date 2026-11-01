import DisplayKit
import ModeDockCore
import SwiftUI

/// A screen's brightness slider, with an Auto toggle when the screen has a light sensor.
struct BrightnessSlider: View {
    let display: Display
    let level: BrightnessController.ScreenBrightness
    let brightness: BrightnessController
    var showsAuto = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.min").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { level.value }, set: { brightness.set($0, for: display.id) }),
                in: level.minimum...1
            ) { editing in
                // Once per drag, when it ends.
                if !editing { Telemetry.shared.record(.screenBrightness) }
            }
            Image(systemName: "sun.max").foregroundStyle(.secondary)
            if showsAuto, let auto = level.autoBrightness {
                AutoChip(isOn: auto) { brightness.setAutoBrightness(!auto, for: display.id) }
            }
        }
        .tip(verbatim: help)
    }

    private var help: String {
        switch level.backend {
        case .system: String(localized: "Brightness of \(display.name).")
        case .ddc: String(localized: "Brightness of \(display.name), set over DDC.")
        case .software:
            String(localized: "\(display.name) has no brightness control, so ModeDock dims the picture.")
        }
    }
}

/// Small "Auto" capsule, filled when automatic brightness is on.
private struct AutoChip: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Auto")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
        .tip(
            isOn
                ? "Automatic brightness is on. Click to turn it off."
                : "Adjust brightness to the light around you.")
    }
}
