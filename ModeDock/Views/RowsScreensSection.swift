import DisplayKit
import KeyboardShortcuts
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
                if let change = modes.pending, change.display == screen.id {
                    PendingResolutionStrip(change: change, modes: modes)
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

            ErrorLabel(controller.lastError ?? modes.lastError)
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
                Button("Turn All On") {
                    Telemetry.shared.record(.screensAllOn)
                    Task { await controller.restoreAll() }
                }
                .buttonStyle(.plain)
                Spacer()
                if let shortcut = KeyboardShortcuts.Name.turnAllScreensOn.shortcutText {
                    Text(verbatim: shortcut).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ScreenRows: View {
    let screen: ScreenController.Screen
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @Environment(MonitorInputController.self) private var inputs
    @State private var confirmingInput: UInt8?
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden

    private var display: Display { screen.display }
    private var screenModes: DisplayModeController.ScreenModes? { modes.screens[screen.id] }

    var body: some View {
        Row {
            Image(systemName: display.systemImage)
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
                    set: {
                        Telemetry.shared.record(.screenToggle)
                        controller.setEnabled($0, screen: screen.id)
                    })
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
                        Text(verbatim: screenModes.label(for: option)).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let option = screenModes.option(containing: screenModes.current), option.modes.count > 1 {
                Divider()
                Row {
                    Text("Refresh Rate")
                    Spacer()
                    Picker("Refresh Rate", selection: refreshRate(screenModes, option)) {
                        ForEach(option.modes) { mode in
                            Text(verbatim: mode.refreshRateText).tag(mode.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if let available = inputs.screens[screen.id] {
                Divider()
                Row {
                    Text("Input")
                    Spacer()
                    Picker("Input", selection: inputSelection(available)) {
                        ForEach(available.available, id: \.self) { Text(available.name(of: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let input = confirmingInput {
                    InputSwitchConfirmation(name: available.name(of: input)) {
                        Task { await inputs.select(input, for: screen.id) }
                        confirmingInput = nil
                    } onCancel: {
                        confirmingInput = nil
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
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

    /// Picking another input asks first: ModeDock can't switch back once the monitor shows it.
    private func inputSelection(_ available: MonitorInputController.Inputs) -> Binding<UInt8> {
        Binding(
            get: { available.current }, set: { input in confirmingInput = input == available.current ? nil : input })
    }

    private func resolution(_ screenModes: DisplayModeController.ScreenModes) -> Binding<String> {
        Binding(
            get: { screenModes.option(containing: screenModes.current)?.id ?? "" },
            set: { id in
                guard let option = screenModes.options.first(where: { $0.id == id }),
                    let mode = screenModes.mode(for: option)
                else { return }
                modes.select(mode, for: screen.id)
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
