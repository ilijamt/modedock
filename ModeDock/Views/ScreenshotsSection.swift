import ModeDockCore
import SwiftUI

extension ScreenshotCoordinator {
    /// The capture buttons to show: All Screens only with more than one screen.
    func visibleModes(hidden: Set<PanelItem>) -> [ScreenshotMode] {
        ScreenshotMode.allCases.filter {
            !hidden.contains($0.item) && ($0 != .allScreens || controller.screenCount > 1)
        }
    }

    func isEnabled(_ mode: ScreenshotMode, savesToClipboard: Bool) -> Bool {
        controller.hasPermission && !controller.isCapturing && !(mode == .allScreens && savesToClipboard)
    }
}

extension ScreenshotMode {
    @MainActor func help(savesToClipboard: Bool) -> String {
        self == .allScreens && savesToClipboard
            ? "All Screens saves to a folder. Choose a folder in Settings → Screenshots." : help
    }
}

/// The Screenshots section in the Cards style: a row of tiles.
struct ScreenshotsSection: View {
    let screenshots: ScreenshotCoordinator
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(SettingsKey.screenshotDestination) private var destination = ScreenshotSettings.folder

    private var controller: ScreenshotController { screenshots.controller }

    var body: some View {
        let toClipboard = destination == ScreenshotSettings.clipboard
        VStack(spacing: 8) {
            if !controller.hasPermission {
                ScreenRecordingPrompt(controller: controller)
            }
            TileGrid {
                ForEach(screenshots.visibleModes(hidden: PanelItem.hidden(in: hiddenItems))) { mode in
                    ActionTile(title: mode.title, systemImage: mode.systemImage) { screenshots.take(mode) }
                        .disabled(!screenshots.isEnabled(mode, savesToClipboard: toClipboard))
                        .help(mode.help(savesToClipboard: toClipboard))
                }
            }
            ErrorLabel(controller.lastError)
        }
        .onAppear(perform: controller.refreshPermission)
    }
}

/// The Screenshots section in the Rows style.
struct RowsScreenshotsSection: View {
    let screenshots: ScreenshotCoordinator
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @AppStorage(SettingsKey.screenshotDestination) private var destination = ScreenshotSettings.folder

    private var controller: ScreenshotController { screenshots.controller }

    var body: some View {
        let toClipboard = destination == ScreenshotSettings.clipboard
        let modes = screenshots.visibleModes(hidden: PanelItem.hidden(in: hiddenItems))
        VStack(spacing: 10) {
            if !controller.hasPermission {
                ScreenRecordingPrompt(controller: controller)
            }
            if !modes.isEmpty {
                RowGroup {
                    ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                        if index > 0 { Divider() }
                        Button {
                            screenshots.take(mode)
                        } label: {
                            Row {
                                Text(mode.menuTitle)
                                Spacer()
                                if let shortcut = mode.shortcut?.shortcutText {
                                    Text(verbatim: shortcut).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!screenshots.isEnabled(mode, savesToClipboard: toClipboard))
                        .help(mode.help(savesToClipboard: toClipboard))
                    }
                }
            }
            ErrorLabel(controller.lastError)
        }
        .controlSize(.small)
        .onAppear(perform: controller.refreshPermission)
    }
}

/// Explains why the capture buttons are off, on a plain background (controls inside glass cards
/// have crashed SwiftUI on macOS 26).
private struct ScreenRecordingPrompt: View {
    let controller: ScreenshotController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ModeDock needs Screen Recording permission to take screenshots.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("After allowing it, quit and reopen ModeDock if the buttons stay off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScreenRecordingButtons(controller: controller)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
