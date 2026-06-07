import KeyboardShortcuts
import ModeDockCore
import SwiftUI

/// The Settings tabs, in order. Each becomes a toolbar item in the Settings window.
enum SettingsTab: String, CaseIterable {
    case general, menu, displays, shortcuts, about

    var title: String {
        switch self {
        case .general: "General"
        case .menu: "Menu"
        case .displays: "Displays"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menu: "menubar.rectangle"
        case .displays: "display.2"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }

    /// Fixed sizes keep the window from jumping between tabs by a few points.
    var height: CGFloat {
        switch self {
        case .general: 250
        case .menu: 250
        case .displays: 500
        case .shortcuts: 150
        case .about: 250
        }
    }

    @MainActor @ViewBuilder
    func content(screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController) -> some View
    {
        switch self {
        case .general: GeneralSettingsView(modes: modes)
        case .menu: MenuSettingsView()
        case .displays: DisplaySettingsView(screens: screens, modes: modes, brightness: brightness)
        case .shortcuts: ShortcutSettingsView()
        case .about: AboutView(screens: screens, modes: modes)
        }
    }
}

private struct GeneralSettingsView: View {
    let modes: DisplayModeController
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: appearance) { AppAppearance.apply() }

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            if let error = launchAtLogin.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section {
                LabeledContent("ModeDock settings") {
                    Button("Reset Settings…") { confirmingReset = true }
                }
            } footer: {
                Text(
                    "Puts every ModeDock setting and keyboard shortcut back to its default. Screens are "
                        + "reset in Displays. Launch at login stays as it is."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
        .confirmationDialog("Reset ModeDock settings?", isPresented: $confirmingReset) {
            Button("Reset Settings", role: .destructive) { ScreenDefaults.resetSettings(modes: modes) }
        } message: {
            Text(
                "Appearance, panel style, menu sections, display options and shortcuts go back to their "
                    + "defaults. ModeDock will ask again before keeping a new resolution."
            )
        }
    }
}

private struct MenuSettingsView: View {
    @AppStorage(SettingsKey.sectionOrder) private var sectionOrder = ""
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue

    private var layout: MenuLayout { MenuLayout(order: sectionOrder, hidden: hiddenSections, collapsed: "") }

    var body: some View {
        Form {
            Section {
                Picker("Panel style", selection: $panelStyle) {
                    ForEach(PanelStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text((PanelStyle(rawValue: panelStyle) ?? .cards).summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(layout.order) { section in
                    Toggle(isOn: visibility(of: section)) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
                .onMove { from, to in
                    var order = layout.order
                    order.move(fromOffsets: from, toOffset: to)
                    sectionOrder = MenuLayout.encode(order)
                }
            } header: {
                Text("Sections")
            } footer: {
                Text("Turn sections on or off, and drag them to change their order in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func visibility(of section: MenuSection) -> Binding<Bool> {
        Binding(
            get: { !layout.hidden.contains(section) },
            set: { visible in
                var hidden = layout.hidden
                if visible { hidden.remove(section) } else { hidden.insert(section) }
                hiddenSections = MenuLayout.encode(hidden)
            }
        )
    }
}

private struct DisplaySettingsView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.showAllModes) private var showAllModes = false
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false
    @AppStorage(SettingsKey.ddcWriteInterval) private var ddcWriteInterval = SettingsKey.ddcWriteIntervalDefault

    var body: some View {
        Form {
            Section {
                Toggle("Show all resolutions", isOn: $showAllModes)
            } footer: {
                Text(
                    "Includes other aspect ratios, low-resolution versions of HiDPI sizes, and modes "
                        + "macOS doesn't offer for the desktop. Some may not display correctly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Monitor brightness updates") {
                    HStack {
                        Slider(value: intervalStep, in: 0...Double(steps.count - 1), step: 1)
                        Text(verbatim: "\(ddcWriteInterval) ms")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } footer: {
                Text(
                    "How often ModeDock sends a new brightness to an external monitor while you drag. "
                        + "Monitors react differently: try a few values and keep the one that looks smoothest."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                ForEach(screens.screens.filter(\.display.isEnabled)) { screen in
                    LabeledContent(screen.display.name) {
                        Button("Reset to Defaults") {
                            ScreenDefaults.reset(screen.id, modes: modes, brightness: brightness)
                        }
                        .disabled(ScreenDefaults.isAtDefault(screen.id, modes: modes, brightness: brightness))
                    }
                }
                LabeledContent("All screens") {
                    Button("Reset All") {
                        ScreenDefaults.resetAll(screens: screens, modes: modes, brightness: brightness)
                    }
                }
            } header: {
                Text("Reset")
            } footer: {
                Text(
                    "Goes back to the resolution and refresh rate macOS picks for the screen, removes "
                        + "software dimming, and turns automatic brightness back on."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Standby for external monitors", isOn: $showDDCStandby)
            } footer: {
                Text(
                    "Standby powers a monitor down over DDC. Some monitors then only wake when you press "
                        + "their power button. Turning a screen off is the safer choice."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Keeps the reset buttons' enabled state current while the window is open.
        .modifier(ModeRefresher(controller: screens, modes: modes, brightness: brightness))
    }

    private var steps: [Int] { SettingsKey.ddcWriteIntervalSteps }

    /// The slider moves through the preset steps rather than every millisecond.
    private var intervalStep: Binding<Double> {
        Binding(
            get: {
                let nearest = steps.indices.min {
                    abs(steps[$0] - ddcWriteInterval) < abs(steps[$1] - ddcWriteInterval)
                }
                return Double(nearest ?? 0)
            },
            set: { ddcWriteInterval = steps[Int($0.rounded())] })
    }
}

private struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Open ModeDock:", name: .togglePanel)
            KeyboardShortcuts.Recorder("Turn all screens on:", name: .turnAllScreensOn)
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.2")
                .font(.system(size: 40))
            Text("ModeDock").font(.title2.bold())
            Text(version).foregroundStyle(.secondary)
            Text("Free and open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = URL(string: "https://github.com/ilijamt/modedock") {
                Link("github.com/ilijamt/modedock", destination: url)
                    .font(.caption)
            }
            Button(copied ? "Copied" : "Copy Diagnostics") {
                Diagnostics.copy(screens: screens, modes: modes)
                copied = true
            }
            .padding(.top, 8)
            .help("Copy details about your screens and macOS, to paste into a bug report.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
