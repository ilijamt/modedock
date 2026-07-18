import AppKit
import ImageIO
import ModeDockCore
import os

/// Experimental: draws the pointer into Area and Window captures, which screencapture leaves it
/// out of. It notes where the pointer was when the capture started, works out what was
/// captured from the clicks during the selection, and draws the cursor there when it's inside.
@MainActor
final class PointerStamp {
    private var start: NSPoint?
    private var cursor: NSCursor?
    private var down: NSPoint?
    private var up: NSPoint?
    private var watcher: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.matoski.modedock", category: "PointerStamp")

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: SettingsKey.screenshotPointer)
            && defaults.bool(forKey: SettingsKey.screenshotPointerEverywhere)
    }

    /// Call just before an interactive capture starts.
    func begin() {
        end()
        start = NSEvent.mouseLocation
        cursor = NSCursor.currentSystem ?? .arrow
        down = nil
        up = nil
        // screencapture keeps the clicks to itself, so event monitors never see them; the
        // button is polled instead, noting where it went down and came back up.
        watcher = Task { [weak self] in
            var wasPressed = NSEvent.pressedMouseButtons & 1 == 1
            while !Task.isCancelled {
                let pressed = NSEvent.pressedMouseButtons & 1 == 1
                if pressed != wasPressed {
                    let location = NSEvent.mouseLocation
                    if pressed { self?.down = location } else { self?.up = location }
                    wasPressed = pressed
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    func end() {
        watcher?.cancel()
        watcher = nil
    }

    /// Draws the pointer into the one captured file, when it was inside what was captured.
    func apply(_ mode: ScreenshotMode, _ files: [URL]) {
        defer { start = nil }
        let captured = capturedRect(mode)
        Self.log.debug(
            "\(mode.rawValue, privacy: .public): start \(String(describing: self.start), privacy: .public) down \(String(describing: self.down), privacy: .public) up \(String(describing: self.up), privacy: .public) captured \(String(describing: captured), privacy: .public)"
        )
        guard mode.isInteractive, files.count == 1, let start, let cursor, let captured, captured.contains(start)
        else { return }
        Self.draw(cursor, at: start, capturedRect: captured, mode: mode, into: files[0])
    }

    /// What was captured, in global screen points with the origin at the bottom left.
    private func capturedRect(_ mode: ScreenshotMode) -> CGRect? {
        switch mode {
        case .area:
            guard let down, let up else { return nil }
            return CGRect(
                x: min(down.x, up.x), y: min(down.y, up.y), width: abs(up.x - down.x), height: abs(up.y - down.y))
        case .window:
            guard let click = up ?? down else { return nil }
            return Self.window(at: click)
        default:
            return nil
        }
    }

    /// The frontmost window under `point` that a window capture could have picked.
    private static func window(at point: NSPoint) -> CGRect? {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let cgPoint = CGPoint(x: point.x, y: top - point.y)
        let list =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let skipped: Set<String> = ["Dock", "Window Server", "screencaptureui"]
        // The menu bar and its status items; panels and pop-ups above them can still be picked.
        let barLayers: Set<Int> = [
            Int(CGWindowLevelForKey(.mainMenuWindow)), Int(CGWindowLevelForKey(.statusWindow)),
        ]
        for info in list {
            // Any window screencapture can pick, panels included, but not the Dock, the menu bar
            // or invisible ones.
            guard (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                !barLayers.contains(info[kCGWindowLayer as String] as? Int ?? 0),
                !skipped.contains(info[kCGWindowOwnerName as String] as? String ?? ""),
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(cgPoint)
            else { continue }
            return CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    private static func draw(
        _ cursor: NSCursor, at point: NSPoint, capturedRect: CGRect, mode: ScreenshotMode, into file: URL
    ) {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let type = CGImageSourceGetType(source), (type as String) != "com.adobe.pdf",
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        // A window capture can include its shadow, which adds a margin around the window; it's
        // taken as even on all sides, hence experimental.
        let marginX = (CGFloat(image.width) / scale - capturedRect.width) / 2
        let marginY = (CGFloat(image.height) / scale - capturedRect.height) / 2
        let x = (point.x - capturedRect.minX + max(marginX, 0)) * scale
        let y = (point.y - capturedRect.minY + max(marginY, 0)) * scale

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let size = cursor.image.size
        let hotSpot = cursor.hotSpot
        let frame = CGRect(
            x: x - hotSpot.x * scale, y: y - (size.height - hotSpot.y) * scale,
            width: size.width * scale, height: size.height * scale)
        var proposed = CGRect(origin: .zero, size: size)
        if let pointer = cursor.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            context.draw(pointer, in: frame)
        }
        guard let stamped = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(file as CFURL, type, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, stamped, nil)
        CGImageDestinationFinalize(destination)
    }
}
