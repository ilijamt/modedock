import KeyboardShortcuts
import ModeDockCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 320)
    }
}

enum SettingsKey {
    static let showDDCStandby = "showDDCStandby"
}

private struct GeneralSettingsView: View {
    @Environment(LaunchAtLogin.self) private var launchAtLogin
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false

    var body: some View {
        Form {
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
            KeyboardShortcuts.Recorder("Open ModeDock:", name: .togglePanel)
            KeyboardShortcuts.Recorder("Turn all screens on:", name: .turnAllScreensOn)

            Section {
                Toggle("Show Standby for external monitors", isOn: $showDDCStandby)
            } footer: {
                Text(
                    "Standby powers a monitor down over DDC. Some monitors then only wake when you press "
                        + "their power button. Turn Off is the safer choice."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

private struct AboutView: View {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
