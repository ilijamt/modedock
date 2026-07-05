import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

public enum ScreenshotMode: String, CaseIterable, Identifiable, Sendable {
    case area, window, screen, allScreens

    public var id: String { rawValue }

    /// Area and window wait for the user to pick what to capture, and can be cancelled with Esc.
    public var isInteractive: Bool { self == .area || self == .window }
}

public enum ScreenshotFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpg, heic, pdf

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPEG"
        case .heic: "HEIC"
        case .pdf: "PDF"
        }
    }
}

/// Where a capture goes: saved in a folder, copied to the clipboard, or both.
public struct ScreenshotDestination: Equatable, Sendable {
    /// Where the files are kept; nil to only copy them.
    public var folder: URL?
    public var copiesToClipboard: Bool

    public init(folder: URL?, copiesToClipboard: Bool) {
        self.folder = folder
        self.copiesToClipboard = copiesToClipboard
    }

    public static func folder(_ url: URL) -> Self { Self(folder: url, copiesToClipboard: false) }
    public static let clipboard = Self(folder: nil, copiesToClipboard: true)
}

public struct ScreenshotOptions: Equatable, Sendable {
    public var destination: ScreenshotDestination
    public var format: ScreenshotFormat
    /// Only possible for screen captures; screencapture refuses it in interactive modes.
    public var includePointer: Bool
    public var playSound: Bool
    public var windowShadow: Bool
    /// Seconds to wait before a screen capture; area and window captures start right away.
    public var delay: Int
    /// All Screens saves one image laid out like the displays instead of a file per screen.
    public var combinesScreens: Bool

    public init(
        destination: ScreenshotDestination, format: ScreenshotFormat = .png, includePointer: Bool = false,
        playSound: Bool = true, windowShadow: Bool = true, delay: Int = 0,
        combinesScreens: Bool = false
    ) {
        self.destination = destination
        self.format = format
        self.includePointer = includePointer
        self.playSound = playSound
        self.windowShadow = windowShadow
        self.delay = delay
        self.combinesScreens = combinesScreens
    }
}

public enum ScreenshotResult: Equatable, Sendable {
    case saved([URL])
    case copied
    case cancelled
    case needsPermission
    case failed
}

/// What the controller needs from macOS, abstracted for tests.
@MainActor
public protocol ScreenshotSystem {
    func hasPermission() -> Bool
    /// Shows the system's Screen Recording prompt (once per app; later calls do nothing).
    func requestPermission()
    /// Runs screencapture with `arguments` and returns its exit status.
    func capture(arguments: [String]) async throws -> Int32
    func fileExists(_ url: URL) -> Bool
    func removeFile(_ url: URL)
    /// Where captures that are only copied are written first.
    func temporaryFolder() -> URL
    /// Puts the image on the clipboard; false when that failed. With `bounds`, one per file, the
    /// images are combined into one, laid out like the displays.
    func copyImages(_ files: [URL], arrangedIn bounds: [CGRect]?) -> Bool
    /// Writes one image of `files` laid out by `bounds` to `file`; false when that failed.
    func combineImages(_ files: [URL], arrangedIn bounds: [CGRect], into file: URL, format: ScreenshotFormat) -> Bool
    /// The display's position and size in the global display space.
    func bounds(of display: CGDirectDisplayID) -> CGRect
    /// screencapture numbers screens from 1 in the order of the active display list.
    func activeDisplays() -> [CGDirectDisplayID]
    /// Where macOS saves screenshots (Screenshot app → Options → Save to), or the Desktop.
    func defaultFolder() -> URL
}

@MainActor
@Observable
public final class ScreenshotController {
    public private(set) var hasPermission: Bool
    public private(set) var lastError: String?
    /// The files the last capture saved; empty when it was only copied.
    public private(set) var lastSaved: [URL] = []
    public private(set) var isCapturing = false

    private let system: ScreenshotSystem

    public init(system: ScreenshotSystem = MacScreenshotSystem()) {
        self.system = system
        hasPermission = system.hasPermission()
    }

    public var defaultFolder: URL { system.defaultFolder() }

    public var screenCount: Int { system.activeDisplays().count }

    public func refreshPermission() {
        hasPermission = system.hasPermission()
    }

    public func requestPermission() {
        system.requestPermission()
        refreshPermission()
    }

    /// Takes a screenshot. `display` is the screen for `.screen`; the main screen when nil.
    @discardableResult
    public func capture(
        _ mode: ScreenshotMode, display: CGDirectDisplayID? = nil, options: ScreenshotOptions, date: Date = .now
    ) async -> ScreenshotResult {
        refreshPermission()
        guard hasPermission else { return .needsPermission }
        guard !isCapturing else { return .cancelled }
        isCapturing = true
        defer { isCapturing = false }
        lastError = nil

        // Always captured to files: screencapture can only copy one image, and copying them
        // ourselves lets All Screens go to the clipboard too.
        let displays = system.activeDisplays()
        let combines = mode == .allScreens && options.combinesScreens
        // Screens that get combined, and captures that are only copied, are written somewhere
        // temporary first.
        let keepsCaptures = options.destination.folder != nil && !combines
        let captureFolder =
            keepsCaptures ? options.destination.folder ?? system.temporaryFolder() : system.temporaryFolder()
        let files = fileURLs(
            in: captureFolder, count: mode == .allScreens ? max(displays.count, 1) : 1, options: options, date: date)
        let index = display.flatMap { displays.firstIndex(of: $0) }.map { $0 + 1 }
        let arguments = Self.arguments(mode: mode, options: options, displayIndex: index, files: files)

        do {
            _ = try await system.capture(arguments: arguments)
        } catch {
            lastError = "The screenshot couldn't be taken: \(error.localizedDescription)"
            return .failed
        }

        let captured = files.filter(system.fileExists)
        guard !captured.isEmpty else {
            // Esc in an interactive capture leaves no file behind; that's the user changing their mind.
            if mode.isInteractive { return .cancelled }
            lastError = "The screenshot couldn't be taken."
            return .failed
        }

        defer { if !keepsCaptures { captured.forEach(system.removeFile) } }
        // All Screens is copied as one image of the whole arrangement, which is what pastes.
        let arrangement = mode == .allScreens && captured.count == displays.count ? displays.map(system.bounds) : nil

        var saved = keepsCaptures ? captured : []
        if let folder = options.destination.folder, combines {
            let file = fileURLs(in: folder, count: 1, options: options, date: date)[0]
            guard let arrangement,
                system.combineImages(captured, arrangedIn: arrangement, into: file, format: options.format)
            else {
                lastError = "The screens couldn't be combined into one image."
                return .failed
            }
            saved = [file]
        }

        if options.destination.copiesToClipboard, !system.copyImages(captured, arrangedIn: arrangement) {
            lastError = "The screenshot couldn't be copied to the clipboard."
            return .failed
        }
        lastSaved = saved
        return saved.isEmpty ? .copied : .saved(saved)
    }

    /// Where each screen's image goes in one image of them all, laid out like the displays: the
    /// canvas size and a frame per screen, in pixels at `scale`, with the origin at the bottom
    /// left. `bounds` are in the global display space, whose origin is the main screen's top left.
    public static func arrangement(of bounds: [CGRect], scale: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        guard let first = bounds.first else { return (.zero, []) }
        let union = bounds.dropFirst().reduce(first) { $0.union($1) }
        let frames = bounds.map { rect in
            CGRect(
                x: (rect.minX - union.minX) * scale, y: (union.maxY - rect.maxY) * scale,
                width: rect.width * scale, height: rect.height * scale)
        }
        return (CGSize(width: union.width * scale, height: union.height * scale), frames)
    }

    /// The screencapture arguments for one capture.
    public static func arguments(
        mode: ScreenshotMode, options: ScreenshotOptions, displayIndex: Int?, files: [URL]
    ) -> [String] {
        var arguments: [String] = []
        if !options.playSound { arguments.append("-x") }
        switch mode {
        case .area:
            arguments += ["-i", "-s"]
        case .window:
            arguments += ["-i", "-w"]
            if !options.windowShadow { arguments.append("-o") }
        case .screen, .allScreens:
            if mode == .screen, let displayIndex { arguments += ["-D", String(displayIndex)] }
            if options.includePointer { arguments.append("-C") }
            if options.delay > 0 { arguments += ["-T", String(options.delay)] }
        }
        arguments += ["-t", options.format.rawValue]
        arguments += files.map(\.path)
        return arguments
    }

    /// "ModeDock 2026-11-15 at 01.23.45.png", numbered per screen for All Screens, and never
    /// overwriting an existing file.
    public func fileURLs(in folder: URL, count: Int, options: ScreenshotOptions, date: Date) -> [URL] {
        let base = "ModeDock \(Self.timestamp(date))"
        let suffixes = count > 1 ? (1...count).map { " (\($0))" } : [""]
        var attempt = 1
        while true {
            let extra = attempt > 1 ? " \(attempt)" : ""
            let urls = suffixes.map {
                folder.appendingPathComponent("\(base)\(extra)\($0).\(options.format.rawValue)")
            }
            if !urls.contains(where: system.fileExists) { return urls }
            attempt += 1
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// The real implementation: `/usr/sbin/screencapture` and the CoreGraphics permission calls.
@MainActor
public struct MacScreenshotSystem: ScreenshotSystem {
    public init() {}

    public func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    public func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    public func capture(arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    public func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    public func removeFile(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    public func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func copyImages(_ files: [URL], arrangedIn bounds: [CGRect]?) -> Bool {
        let images = Self.loadImages(files)
        guard !images.isEmpty, images.count == files.count else { return false }
        let image: CGImage
        if let bounds, bounds.count == images.count, images.count > 1 {
            guard let combined = Self.combine(images, bounds: bounds) else { return false }
            image = combined
        } else {
            image = images[0]
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        NSPasteboard.general.clearContents()
        // PNG for apps that take it, TIFF for the ones that only take that.
        return NSPasteboard.general.setData(png, forType: .png)
            && NSPasteboard.general.setData(rep.tiffRepresentation, forType: .tiff)
    }

    public func bounds(of display: CGDirectDisplayID) -> CGRect { CGDisplayBounds(display) }

    public func combineImages(
        _ files: [URL], arrangedIn bounds: [CGRect], into file: URL, format: ScreenshotFormat
    ) -> Bool {
        let images = Self.loadImages(files)
        guard images.count == files.count, let image = Self.combine(images, bounds: bounds) else { return false }
        if format == .pdf {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let context = CGContext(file as CFURL, mediaBox: &box, nil) else { return false }
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
            context.closePDF()
            return true
        }
        let type: UTType =
            switch format {
            case .jpg: .jpeg
            case .heic: .heic
            default: .png
            }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func loadImages(_ files: [URL]) -> [CGImage] {
        files.compactMap { url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// Draws each screen's image where its display is, at the sharpest screen's scale so Retina
    /// detail is kept. Gaps between displays stay transparent.
    private static func combine(_ images: [CGImage], bounds: [CGRect]) -> CGImage? {
        let scale = zip(images, bounds).map { CGFloat($0.width) / max($1.width, 1) }.max() ?? 1
        let layout = ScreenshotController.arrangement(of: bounds, scale: scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard
            let context = CGContext(
                data: nil, width: Int(layout.size.width.rounded()), height: Int(layout.size.height.rounded()),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        for (image, frame) in zip(images, layout.frames) {
            context.draw(image, in: frame)
        }
        return context.makeImage()
    }

    public func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    public func defaultFolder() -> URL {
        let location =
            CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let location, !location.isEmpty {
            var isDirectory: ObjCBool = false
            let path = (location as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
