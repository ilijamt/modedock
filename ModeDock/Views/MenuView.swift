import ModeDockCore
import SwiftUI

struct MenuView: View {
    let screens: ScreenController
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ModeDock")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            ScreensSection(controller: screens)
                .padding(.vertical, 6)

            Divider()

            HStack {
                Button("Settings…", action: onOpenSettings)
                    .keyboardShortcut(",")

                Spacer()

                Button("Quit ModeDock") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 320)
    }
}

private struct ScreensSection: View {
    let controller: ScreenController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Screens")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            ForEach(controller.screens) { screen in
                ScreenRow(screen: screen, controller: controller)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }

            HStack {
                Button("Sleep All Screens", systemImage: "moon") {
                    controller.sleepAllDisplays()
                }
                Spacer()
                Button("Turn All On", systemImage: "power") {
                    Task { await controller.restoreAll() }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

private struct ScreenRow: View {
    let screen: ScreenController.Screen
    let controller: ScreenController
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false

    private var status: (String, Color) {
        if !screen.display.isEnabled { return ("Off", .secondary) }
        if screen.isInStandby { return ("Standby", .orange) }
        return ("On", .green)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: screen.display.isBuiltin ? "laptopcomputer" : "display")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(screen.display.name).lineLimit(1)
                Text(status.0).font(.caption).foregroundStyle(status.1)
            }
            Spacer()

            if showDDCStandby && screen.supportsDDC && screen.display.isEnabled {
                Button(screen.isInStandby ? "Wake" : "Standby") {
                    Task { await controller.setStandby(!screen.isInStandby, screen: screen.id) }
                }
                .help(
                    "Put the monitor in standby over DDC. Windows stay put, "
                        + "but some monitors only wake with their power button.")
            }

            Button(screen.display.isEnabled ? "Turn Off" : "Turn On") {
                controller.setEnabled(!screen.display.isEnabled, screen: screen.id)
            }
            .disabled(screen.display.isEnabled && !screen.canDisable)
            .help(
                screen.display.isEnabled && !screen.canDisable
                    ? "At least one screen has to stay on."
                    : "Disconnect the screen from macOS. Its windows move to your other screens.")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
