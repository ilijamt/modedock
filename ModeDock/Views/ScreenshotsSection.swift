import ModeDockCore
import SwiftUI

extension ScreenshotCoordinator {
    /// The capture buttons to show: All Screens only with more than one screen.
    func visibleModes(hidden: Set<PanelItem>) -> [ScreenshotMode] {
        ScreenshotMode.allCases.filter {
            !hidden.contains($0.item) && ($0 != .allScreens || controller.screenCount > 1)
        }
    }

    var canCapture: Bool { controller.hasPermission && !controller.isCapturing }
}

/// The Screenshots section in the Cards style: a row of tiles.
struct ScreenshotsSection: View {
    let screenshots: ScreenshotCoordinator
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    private var controller: ScreenshotController { screenshots.controller }

    var body: some View {
        VStack(spacing: 8) {
            if !controller.hasPermission {
                ScreenRecordingPrompt(controller: controller)
            }
            TileGrid {
                ForEach(screenshots.visibleModes(hidden: PanelItem.hidden(in: hiddenItems))) { mode in
                    let shortcut = mode.shortcut?.shortcutText
                    ActionTile(
                        title: mode.title, systemImage: mode.systemImage, detail: shortcut ?? "Not set",
                        detailIsPlaceholder: shortcut == nil
                    ) { screenshots.take(mode) }
                    .disabled(!screenshots.canCapture)
                    .tip(mode.help)
                }
            }
            if !PanelItem.hidden(in: hiddenItems).contains(.screenshotOptions) {
                ScreenshotOptionsStrip()
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
    private var controller: ScreenshotController { screenshots.controller }

    var body: some View {
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
                                } else {
                                    Text("Not set").foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!screenshots.canCapture)
                        .tip(mode.help)
                    }
                }
            }
            if !PanelItem.hidden(in: hiddenItems).contains(.screenshotOptions) {
                ScreenshotOptionsStrip()
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

/// Where captures go and the timer, so they can be changed without opening Settings. Outside
/// the glass cards, and chips rather than a segmented picker, which crashed inside glass.
struct ScreenshotOptionsStrip: View {
    @AppStorage(SettingsKey.screenshotDestination) private var destination = ScreenshotSettings.folder
    @AppStorage(SettingsKey.screenshotDelay) private var delay = 0
    @AppStorage(SettingsKey.screenshotNotice) private var showNotice = true
    @AppStorage(SettingsKey.screenshotNoticePicture) private var showPicture = true
    @AppStorage(SettingsKey.screenshotSound) private var playSound = true
    @AppStorage(SettingsKey.screenshotHidesPanel) private var hidesPanel = true
    @AppStorage(SettingsKey.screenshotPointer) private var includePointer = false

    private var savesToFolder: Bool { ScreenshotSettings.savesToFolder(destination) }
    private var copiesToClipboard: Bool { ScreenshotSettings.copiesToClipboard(destination) }

    /// Turning off the only one that's on does nothing: a capture has to go somewhere.
    private func set(savesToFolder: Bool, copiesToClipboard: Bool) {
        guard savesToFolder || copiesToClipboard else { return }
        destination = ScreenshotSettings.value(savesToFolder: savesToFolder, copiesToClipboard: copiesToClipboard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Save to").font(.callout)
                Spacer(minLength: 4)
                Chip(title: "Folder", isOn: savesToFolder) {
                    set(savesToFolder: !savesToFolder, copiesToClipboard: copiesToClipboard)
                }
                .tip("Save a file in the screenshot folder")
                Chip(title: "Clipboard", isOn: copiesToClipboard) {
                    set(savesToFolder: savesToFolder, copiesToClipboard: !copiesToClipboard)
                }
                .tip("Copy the image, ready to paste. Both can be on.")
            }
            HStack(spacing: 4) {
                Text("Timer").font(.callout)
                Spacer(minLength: 4)
                ForEach(ScreenshotSettings.delays, id: \.self) { seconds in
                    Chip(title: seconds == 0 ? "Off" : "\(seconds)s", isOn: delay == seconds) { delay = seconds }
                        .tip(seconds == 0 ? "Capture straight away" : "Wait \(seconds) seconds before capturing")
                }
            }
            HStack(spacing: 4) {
                Text("Include").font(.callout)
                Spacer(minLength: 4)
                Chip(title: "Pointer", isOn: includePointer) { includePointer.toggle() }
                    .tip(
                        "Show the mouse pointer in Screen and All Screens captures. For Area and Window, see the experimental option in Settings → Capture."
                    )
                Chip(title: "ModeDock", isOn: !hidesPanel) { hidesPanel.toggle() }
                    .tip("Leave this panel open, so it's in the screenshot too")
            }
            HStack(spacing: 4) {
                Text("After").font(.callout)
                Spacer(minLength: 4)
                Chip(title: "Preview", isOn: showNotice) { showNotice.toggle() }
                    .tip("Show a card with the screenshot after capturing")
                Chip(title: "Picture", isOn: showNotice && showPicture) { showPicture.toggle() }
                    .disabled(!showNotice)
                    .opacity(showNotice ? 1 : 0.5)
                    .tip("Show the screenshot in the card, not just an icon")
                Chip(title: "Sound", isOn: playSound) { playSound.toggle() }
                    .tip("Play the camera sound")
            }
        }
        .padding(10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
