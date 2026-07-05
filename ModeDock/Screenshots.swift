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
            case .allScreens: "Capture every screen, one file each."
            }
        guard let shortcut = shortcut?.shortcutText else { return text }
        return "\(text) (\(shortcut))"
    }
}

/// The Settings → Screenshots preferences, as the options a capture takes.
enum ScreenshotSettings {
    static let folder = "folder"
    static let clipboard = "clipboard"
    static let delays = [0, 3, 5, 10]

    static var savesToClipboard: Bool {
        UserDefaults.standard.string(forKey: SettingsKey.screenshotDestination) == clipboard
    }

    /// The chosen folder, or macOS's own screenshot location when none was chosen.
    static func folderURL(default defaultFolder: URL) -> URL {
        let path = UserDefaults.standard.string(forKey: SettingsKey.screenshotFolder) ?? ""
        return path.isEmpty ? defaultFolder : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func options(defaultFolder: URL) -> ScreenshotOptions {
        let defaults = UserDefaults.standard
        return ScreenshotOptions(
            destination: savesToClipboard ? .clipboard : .folder(folderURL(default: defaultFolder)),
            format: defaults.string(forKey: SettingsKey.screenshotFormat).flatMap(ScreenshotFormat.init) ?? .png,
            includePointer: defaults.bool(forKey: SettingsKey.screenshotPointer),
            playSound: defaults.object(forKey: SettingsKey.screenshotSound) as? Bool ?? true,
            windowShadow: defaults.object(forKey: SettingsKey.screenshotShadow) as? Bool ?? true,
            delay: defaults.integer(forKey: SettingsKey.screenshotDelay)
        )
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

    init(controller: ScreenshotController) {
        self.controller = controller
    }

    func take(_ mode: ScreenshotMode) {
        closePanel()
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
            try? await Task.sleep(for: .milliseconds(300))
            let result = await controller.capture(mode, display: display, options: options)
            switch result {
            case .saved(let files) where ScreenshotSettings.showsNotice:
                notice.show(.saved(files), controller: controller)
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
    case saved([URL])
    case copied
    case failed(String)
    case permission

    var duration: Duration {
        switch self {
        case .saved: .seconds(4)
        case .copied: .seconds(1.5)
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
        case .saved(let files):
            Button {
                if let file = files.first { NSWorkspace.shared.open(file) }
            } label: {
                Thumbnail(url: files.first)
            }
            .buttonStyle(.plain)
            .help("Open the screenshot")
        case .copied:
            Image(systemName: "doc.on.clipboard").font(.system(size: 24)).frame(width: 40)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
                .frame(width: 40)
        case .permission:
            Image(systemName: "lock.shield").font(.system(size: 24)).frame(width: 40)
        }
    }

    private var title: String {
        switch notice {
        case .saved(let files): files.count == 1 ? "Screenshot Saved" : "\(files.count) Screenshots Saved"
        case .copied: "Screenshot Copied"
        case .failed: "Screenshot Failed"
        case .permission: "Screen Recording Needed"
        }
    }

    private var detail: String? {
        switch notice {
        case .saved(let files):
            files.first.map { files.count == 1 ? $0.lastPathComponent : $0.deletingLastPathComponent().path }
        case .copied: "Paste it into any app."
        case .failed(let message): message
        case .permission: "Allow ModeDock to record the screen in System Settings to take screenshots."
        }
    }

    @ViewBuilder private var buttons: some View {
        switch notice {
        case .saved(let files):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(files)
                onClose()
            }
            .controlSize(.small)
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
    let url: URL?

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
        guard let url else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 288,
            ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}
