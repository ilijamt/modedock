import AppKit
import ImageIO
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

extension KeyboardShortcuts.Name {
    // No defaults: ⇧⌘3, ⇧⌘4 and ⇧⌘5 already belong to macOS.
    static let captureArea = Self("captureArea")
    static let captureWindow = Self("captureWindow")
    static let captureScreen = Self("captureScreen")
    static let captureAllScreens = Self("captureAllScreens")
}

extension ScreenshotMode {
    var title: String {
        switch self {
        case .area: "Area"
        case .window: "Window"
        case .screen: "Screen"
        case .allScreens: "All Screens"
        }
    }

    var menuTitle: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .screen: "Capture Screen"
        case .allScreens: "Capture All Screens"
        }
    }

    var systemImage: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .allScreens: "display.2"
        }
    }

    var item: PanelItem {
        switch self {
        case .area: .screenshotArea
        case .window: .screenshotWindow
        case .screen: .screenshotScreen
        case .allScreens: .screenshotAllScreens
        }
    }

    var shortcut: KeyboardShortcuts.Name? {
        switch self {
        case .area: .captureArea
        case .window: .captureWindow
        case .screen: .captureScreen
        case .allScreens: .captureAllScreens
        }
    }

    @MainActor var help: String {
        let text =
            switch self {
            case .area: "Drag to select part of the screen. Press Esc to cancel."
            case .window: "Click a window to capture it. Press Esc to cancel."
            case .screen: "Capture the screen under the pointer."
            case .allScreens: "Capture every screen."
            }
        guard let shortcut = shortcut?.shortcutText else { return text }
        return "\(text) (\(shortcut))"
    }
}

/// The Settings → Capture preferences, as the options a capture takes.
enum ScreenshotSettings {
    // The values of SettingsKey.screenshotDestination.
    static let folder = "folder"
    static let clipboard = "clipboard"
    static let both = "both"
    static let delays = [0, 3, 5, 10]

    static func savesToFolder(_ value: String) -> Bool { value != clipboard }
    static func copiesToClipboard(_ value: String) -> Bool { value == clipboard || value == both }

    /// The setting for a combination; at least one of the two stays on.
    static func value(savesToFolder: Bool, copiesToClipboard: Bool) -> String {
        switch (savesToFolder, copiesToClipboard) {
        case (true, true): both
        case (false, true): clipboard
        default: folder
        }
    }

    private static var destination: String {
        UserDefaults.standard.string(forKey: SettingsKey.screenshotDestination) ?? folder
    }

    /// The chosen folder, or macOS's own screenshot location when none was chosen.
    static func folderURL(default defaultFolder: URL) -> URL {
        let path = UserDefaults.standard.string(forKey: SettingsKey.screenshotFolder) ?? ""
        return path.isEmpty ? defaultFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func options(defaultFolder: URL) -> ScreenshotOptions {
        let defaults = UserDefaults.standard
        return ScreenshotOptions(
            destination: ScreenshotDestination(
                folder: savesToFolder(destination) ? folderURL(default: defaultFolder) : nil,
                copiesToClipboard: copiesToClipboard(destination)),
            format: defaults.string(forKey: SettingsKey.screenshotFormat).flatMap(ScreenshotFormat.init) ?? .png,
            includePointer: defaults.bool(forKey: SettingsKey.screenshotPointer),
            playSound: defaults.object(forKey: SettingsKey.screenshotSound) as? Bool ?? true,
            windowShadow: defaults.object(forKey: SettingsKey.screenshotShadow) as? Bool ?? true,
            delay: defaults.integer(forKey: SettingsKey.screenshotDelay),
            combinesScreens: defaults.object(forKey: SettingsKey.screenshotCombineScreens) as? Bool ?? true
        )
    }

    static var hidesPanel: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.screenshotHidesPanel) as? Bool ?? true
    }

    static var showsNoticePicture: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.screenshotNoticePicture) as? Bool ?? true
    }

    static var showsNotice: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.screenshotNotice) as? Bool ?? true
    }

    static func openPrivacySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Starts captures from the panel, the menu and the shortcuts, and shows the result.
@MainActor
final class ScreenshotCoordinator {
    let controller: ScreenshotController
    /// Closes the panel, so it isn't in the screenshot.
    var closePanel: () -> Void = {}
    private let notice = ScreenshotNoticeWindow()

    private let pointerStamp = PointerStamp()

    init(controller: ScreenshotController) {
        self.controller = controller
        controller.processCaptures = { [pointerStamp] mode, files in pointerStamp.apply(mode, files) }
    }

    func take(_ mode: ScreenshotMode) {
        // Before the panel closes, so it's where the pointer was when the capture was asked for.
        if mode.isInteractive, PointerStamp.isEnabled { pointerStamp.begin() }
        let hidesPanel = ScreenshotSettings.hidesPanel
        if hidesPanel { closePanel() }
        notice.close()
        controller.refreshPermission()
        guard controller.hasPermission else {
            notice.show(.permission, controller: controller)
            return
        }
        let display = NSScreen.underMouse?.displayID
        let options = ScreenshotSettings.options(defaultFolder: controller.defaultFolder)
        Task {
            // Give the panel or menu time to leave the screen.
            if hidesPanel { try? await Task.sleep(for: .milliseconds(300)) }
            let result = await controller.capture(mode, display: display, options: options)
            pointerStamp.end()
            switch result {
            case .saved(let files) where ScreenshotSettings.showsNotice:
                notice.show(.saved(files, copied: options.destination.copiesToClipboard), controller: controller)
            case .copied where ScreenshotSettings.showsNotice:
                notice.show(.copied, controller: controller)
            case .failed:
                notice.show(
                    .failed(controller.lastError ?? "The screenshot couldn't be taken."), controller: controller)
            case .needsPermission:
                notice.show(.permission, controller: controller)
            default:
                break
            }
        }
    }
}

enum ScreenshotNotice: Equatable {
    case saved([URL], copied: Bool)
    case copied
    case failed(String)
    case permission

    var duration: Duration {
        switch self {
        case .saved: .seconds(4)
        case .copied: .seconds(3)
        case .failed: .seconds(6)
        case .permission: .seconds(12)
        }
    }
}

/// A small card near the bottom-right corner after a capture; it goes away on its own.
@MainActor
final class ScreenshotNoticeWindow {
    private var panel: FloatingPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ notice: ScreenshotNotice, controller: ScreenshotController) {
        close()
        let panel = NoticePanel()
        panel.setContent(
            NoticeView(notice: notice, controller: controller) { [weak self] in self?.close() }, cornerRadius: 14)
        if let view = panel.contentViewController?.view {
            panel.setContentSize(view.fittingSize)
        }
        if let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame {
            let margin: CGFloat = 16
            panel.setFrameOrigin(
                NSPoint(x: visible.maxX - panel.frame.width - margin, y: visible.minY + margin))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: notice.duration)
            // Stays while the pointer is over it, so its buttons can still be reached.
            while let panel = self?.panel, panel.frame.contains(NSEvent.mouseLocation), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class NoticePanel: FloatingPanel {
    init() {
        super.init(level: .statusBar)
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
}

private struct NoticeView: View {
    let notice: ScreenshotNotice
    let controller: ScreenshotController
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                buttons
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 340)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .padding(8)
            .help("Close")
        }
    }

    @ViewBuilder private var leading: some View {
        switch notice {
        case .saved(let files, _):
            Button {
                if let file = files.first { NSWorkspace.shared.open(file) }
            } label: {
                if ScreenshotSettings.showsNoticePicture {
                    Thumbnail(url: files.first)
                } else {
                    Image(systemName: "photo").font(.system(size: 24)).frame(width: 40)
                }
            }
            .buttonStyle(.plain)
            .help("Open the screenshot")
        case .copied:
            if ScreenshotSettings.showsNoticePicture {
                // Only copied, so there's no file: the picture comes from the clipboard.
                Thumbnail(
                    source: NSPasteboard.general.data(forType: .png).flatMap {
                        CGImageSourceCreateWithData($0 as CFData, nil)
                    })
            } else {
                Image(systemName: "doc.on.clipboard").font(.system(size: 24)).frame(width: 40)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
                .frame(width: 40)
        case .permission:
            Image(systemName: "lock.shield").font(.system(size: 24)).frame(width: 40)
        }
    }

    private var title: String {
        switch notice {
        case .saved(let files, let copied):
            (files.count == 1 ? "Screenshot Saved" : "\(files.count) Screenshots Saved") + (copied ? " and Copied" : "")
        case .copied: "Screenshot Copied"
        case .failed: "Screenshot Failed"
        case .permission: "Screen Recording Needed"
        }
    }

    private var detail: String? {
        switch notice {
        case .saved(let files, _):
            files.first.map { files.count == 1 ? $0.lastPathComponent : $0.deletingLastPathComponent().path }
        case .copied: "Paste it into any app."
        case .failed(let message): message
        case .permission: "Allow ModeDock to record the screen in System Settings to take screenshots."
        }
    }

    /// Turns off Settings → Capture → "Show a preview after capturing". Errors still show.
    private var dontShowAgain: some View {
        Button("Don't Show Again") {
            UserDefaults.standard.set(false, forKey: SettingsKey.screenshotNotice)
            onClose()
        }
        .help("Turn the preview back on in Settings → Capture.")
    }

    @ViewBuilder private var buttons: some View {
        switch notice {
        case .saved(let files, _):
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(files)
                    onClose()
                }
                dontShowAgain
            }
            .controlSize(.small)
        case .copied:
            dontShowAgain.controlSize(.small)
        case .permission:
            ScreenRecordingButtons(controller: controller)
        default:
            EmptyView()
        }
    }
}

/// "Allow…" shows the system prompt the first time; after that only System Settings can change it.
struct ScreenRecordingButtons: View {
    let controller: ScreenshotController

    var body: some View {
        HStack {
            Button("Allow…") { controller.requestPermission() }
            Button("Open Settings") { ScreenshotSettings.openPrivacySettings() }
        }
        .controlSize(.small)
    }
}

/// A small preview of the saved image, or the file's icon when it can't be read (PDF).
private struct Thumbnail: View {
    let source: CGImageSource?
    /// Shown when there's no picture, such as a PDF.
    var url: URL?

    init(url: URL?) {
        self.source = url.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        self.url = url
    }

    init(source: CGImageSource?) {
        self.source = source
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").font(.system(size: 24))
            }
        }
        .frame(width: 72, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var image: NSImage? {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 288,
            ] as CFDictionary
        guard let source, let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

/// Hands macOS's ⇧⌘3 and ⇧⌘4 screenshot shortcuts (and their ⌃ clipboard versions) to ModeDock,
/// and back. macOS keeps them in com.apple.symbolichotkeys; a missing entry means "on".
@MainActor
enum SystemScreenshotKeys {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    /// ⇧⌘ and ⌃⇧⌘ in the modifier format these entries use.
    private static let shiftCommand = 1_179_648
    private static let controlShiftCommand = 1_441_792
    /// Hot key ID → (character, key code, modifiers), as macOS writes them.
    private static let entries: [String: [Int]] = [
        "28": [51, 20, shiftCommand],  // Save picture of screen as a file
        "29": [51, 20, controlShiftCommand],  // Copy picture of screen to the clipboard
        "30": [52, 21, shiftCommand],  // Save picture of selected area as a file
        "31": [52, 21, controlShiftCommand],  // Copy picture of selected area to the clipboard
    ]

    private static var hotKeys: [String: Any] {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    /// Whether macOS's own shortcuts are off, so ModeDock can use the keys.
    static var areTakenOver: Bool {
        let keys = hotKeys
        return entries.keys.allSatisfy { ((keys[$0] as? [String: Any])?["enabled"] as? Bool) == false }
    }

    static func takeOver(_ on: Bool) {
        var keys = hotKeys
        for (id, parameters) in entries {
            var entry = keys[id] as? [String: Any] ?? [:]
            entry["enabled"] = !on
            if entry["value"] == nil {
                entry["value"] = ["parameters": parameters, "type": "standard"]
            }
            keys[id] = entry
        }
        CFPreferencesSetValue(key, keys as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // Makes the change take effect without logging out.
        let activate = Process()
        activate.executableURL = URL(
            fileURLWithPath:
                "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        activate.arguments = ["-u"]
        try? activate.run()
        activate.waitUntilExit()

        let screen = KeyboardShortcuts.Shortcut(.three, modifiers: [.shift, .command])
        let area = KeyboardShortcuts.Shortcut(.four, modifiers: [.shift, .command])
        if on {
            KeyboardShortcuts.setShortcut(screen, for: .captureScreen)
            KeyboardShortcuts.setShortcut(area, for: .captureArea)
        } else {
            // Only clear them if they're still the keys handed back to macOS.
            if KeyboardShortcuts.getShortcut(for: .captureScreen) == screen {
                KeyboardShortcuts.setShortcut(nil, for: .captureScreen)
            }
            if KeyboardShortcuts.getShortcut(for: .captureArea) == area {
                KeyboardShortcuts.setShortcut(nil, for: .captureArea)
            }
        }
    }
}
