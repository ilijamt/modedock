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
        case .general: 150
        case .menu: 250
        case .displays: 270
        case .shortcuts: 150
        case .about: 250
        }
    }

    @MainActor @ViewBuilder
    func content(screens: ScreenController, modes: DisplayModeController) -> some View {
        switch self {
        case .general: GeneralSettingsView()
        case .menu: MenuSettingsView()
        case .displays: DisplaySettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .about: AboutView(screens: screens, modes: modes)
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

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
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
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
    @AppStorage(SettingsKey.showAllModes) private var showAllModes = false
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false

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
