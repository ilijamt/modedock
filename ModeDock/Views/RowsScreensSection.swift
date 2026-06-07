import DisplayKit
import ModeDockCore
import SwiftUI

/// Screens shown as grouped rows with standard controls, like the Settings window.
struct RowsScreensSection: View {
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(controller.screens) { screen in
                RowGroup {
                    ScreenRows(screen: screen, controller: controller, modes: modes, brightness: brightness)
                }
            }

            if !actions.isEmpty {
                RowGroup {
                    ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider() }
                        actionRow(action)
                    }
                }
            }

            if let error = controller.lastError ?? modes.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
    }

    /// The optional rows under the screens, in order, without the hidden ones.
    private var actions: [PanelItem] {
        [PanelItem.mirror, .sleepScreens, .allOn].filter { item in
            guard !hidden.contains(item) else { return false }
            return item != .mirror || modes.canMirror || modes.isMirroring
        }
    }

    @ViewBuilder private func actionRow(_ item: PanelItem) -> some View {
        switch item {
        case .mirror:
            Row {
                Text("Mirror Screens")
                Spacer()
                Toggle(
                    "Mirror Screens",
                    isOn: Binding(get: { modes.isMirroring }, set: { modes.setMirroring($0) })
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }
        case .sleepScreens:
            Row {
                Button("Sleep All Screens") { controller.sleepAllDisplays() }
                    .buttonStyle(.plain)
                Spacer()
            }
        default:
            Row {
                Button("Turn All On") { Task { await controller.restoreAll() } }
                    .buttonStyle(.plain)
                Spacer()
                Text("⌃⌥⌘O").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScreenRows: View {
    let screen: ScreenController.Screen
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden

    private var display: Display { screen.display }
    private var screenModes: DisplayModeController.ScreenModes? { modes.screens[screen.id] }

    var body: some View {
        Row {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                .frame(width: 20)
            Text(display.name).lineLimit(1)
            if screenModes?.isMain == true && display.isEnabled {
                Text("Main").foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "On",
                isOn: Binding(
                    get: { display.isEnabled },
                    set: { controller.setEnabled($0, screen: screen.id) })
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(display.isEnabled && !screen.canDisable)
        }

        if display.isEnabled, let screenModes {
            Divider()
            Row {
                Text("Resolution")
                Spacer()
                Picker("Resolution", selection: resolution(screenModes)) {
                    ForEach(screenModes.options) { option in
                        Text(verbatim: label(option, in: screenModes)).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let option = currentOption(screenModes), option.modes.count > 1 {
                Divider()
                Row {
                    Text("Refresh Rate")
                    Spacer()
                    Picker("Refresh Rate", selection: refreshRate(screenModes, option)) {
                        ForEach(option.modes) { mode in
                            Text(verbatim: "\(Int(mode.refreshRate.rounded())) Hz").tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if !PanelItem.hidden(in: hiddenItems).contains(.brightness), let level = brightness.screens[screen.id] {
                Divider()
                Row {
                    Text("Brightness")
                    BrightnessSlider(display: display, level: level, brightness: brightness, showsAuto: false)
                }
                if let auto = level.autoBrightness {
                    Divider()
                    Row {
                        Text("Automatic Brightness")
                        Spacer()
                        Toggle(
                            "Automatic Brightness",
                            isOn: Binding(get: { auto }, set: { brightness.setAutoBrightness($0, for: screen.id) })
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            if !screenModes.isMain {
                Divider()
                Row {
                    Button("Use as Main Screen") { modes.makeMain(screen.id) }
                        .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    private func currentOption(_ screenModes: DisplayModeController.ScreenModes) -> ResolutionOption? {
        screenModes.options.first { $0.modes.contains { $0.id == screenModes.current?.id } }
    }

    /// Picking a size keeps the current refresh rate when that size offers it, otherwise the highest.
    private func resolution(_ screenModes: DisplayModeController.ScreenModes) -> Binding<String> {
        Binding(
            get: { currentOption(screenModes)?.id ?? "" },
            set: { id in
                guard let option = screenModes.options.first(where: { $0.id == id }) else { return }
                let rate = screenModes.current.map { Int($0.refreshRate.rounded()) }
                let mode = option.modes.first { Int($0.refreshRate.rounded()) == rate } ?? option.modes.first
                if let mode { modes.select(mode, for: screen.id) }
            })
    }

    private func refreshRate(
        _ screenModes: DisplayModeController.ScreenModes, _ option: ResolutionOption
    ) -> Binding<Int32> {
        Binding(
            get: { screenModes.current?.id ?? 0 },
            set: { id in
                if let mode = option.modes.first(where: { $0.id == id }) { modes.select(mode, for: screen.id) }
            })
    }

    private func label(_ option: ResolutionOption, in screenModes: DisplayModeController.ScreenModes) -> String {
        var text = "\(option.width) × \(option.height)"
        let hasHiDPIVersion = screenModes.options.contains {
            $0.isHiDPI && $0.width == option.width && $0.height == option.height
        }
        if !option.isHiDPI && hasHiDPIVersion { text += " (low resolution)" }
        if option.isNative { text += " · Native" }
        return text
    }
}

/// A rounded group of rows, like a grouped Form section.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Row<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
    }
}
