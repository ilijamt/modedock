import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

public enum ScreenshotMode: String, CaseIterable, Identifiable, Sendable {
    case area, window, screen, allScreens

    public var id: String { rawValue }

    var telemetryEvent: TelemetryEvent {
        switch self {
        case .area: .captureArea
        case .window: .captureWindow
        case .screen: .captureScreen
        case .allScreens: .captureAllScreens
        }
    }

    public var isInteractive: Bool { self == .area || self == .window }
}

public enum ScreenshotFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpg, heic, pdf

    public var id: String { rawValue }

    var type: UTType {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .heic: .heic
        case .pdf: .pdf
        }
    }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPEG"
        case .heic: "HEIC"
        case .pdf: "PDF"
        }
    }
}

public struct ScreenshotDestination: Equatable, Sendable {
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
    /// screencapture refuses it in interactive modes.
    public var includePointer: Bool
    public var playSound: Bool
    public var windowShadow: Bool
    public var delay: Int
    public var combinesScreens: Bool
    /// Only files saved as captured keep the extended range.
    public var hdr: Bool

    /// screencapture writes HDR captures as HEIC whatever format is asked for.
    public var fileFormat: ScreenshotFormat { hdr ? .heic : format }

    public init(
        destination: ScreenshotDestination, format: ScreenshotFormat = .png, includePointer: Bool = false,
        playSound: Bool = true, windowShadow: Bool = true, delay: Int = 0,
        combinesScreens: Bool = false, hdr: Bool = false
    ) {
        self.destination = destination
        self.format = format
        self.includePointer = includePointer
        self.playSound = playSound
        self.windowShadow = windowShadow
        self.delay = delay
        self.combinesScreens = combinesScreens
        self.hdr = hdr
    }
}

public enum ScreenshotResult: Equatable, Sendable {
    case saved([URL])
    case copied
    case cancelled
    case needsPermission
    case failed
}

@MainActor
public protocol ScreenshotSystem {
    func hasPermission() -> Bool
    /// Later calls do nothing.
    func requestPermission()
    func capture(arguments: [String]) async throws -> Int32
    func fileExists(_ url: URL) -> Bool
    func removeFile(_ url: URL)
    func temporaryFolder() -> URL
    func copyImages(_ files: [URL], arrangedIn bounds: [CGRect]?, hdr: Bool) -> Bool
    func combineImages(
        _ files: [URL], arrangedIn bounds: [CGRect], into file: URL, format: ScreenshotFormat, hdr: Bool
    ) -> Bool
    func bounds(of display: CGDirectDisplayID) -> CGRect
    /// screencapture numbers screens from 1 in the order of the active display list.
    func activeDisplays() -> [CGDirectDisplayID]
    func defaultFolder() -> URL
}

@MainActor
@Observable
public final class ScreenshotController {
    public private(set) var hasPermission: Bool
    public private(set) var lastError: String? {
        // Only the error kind is counted, never its text.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorCapture) } }
    }
    public private(set) var lastSaved: [URL] = []
    public private(set) var isCapturing = false
    /// For example to draw the pointer where screencapture leaves it out.
    public var processCaptures: ((ScreenshotMode, [URL]) -> Void)?

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

    @discardableResult
    public func capture(
        _ mode: ScreenshotMode, display: CGDirectDisplayID? = nil, options: ScreenshotOptions, date: Date = .now
    ) async -> ScreenshotResult {
        refreshPermission()
        guard hasPermission else { return .needsPermission }
        Telemetry.shared.record(mode.telemetryEvent)
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
        let keptFolder = combines ? nil : options.destination.folder
        let keepsCaptures = keptFolder != nil
        let captureFolder = keptFolder ?? system.temporaryFolder()
        let files = fileURLs(
            in: captureFolder, count: mode == .allScreens ? max(displays.count, 1) : 1, options: options, date: date)
        let index = display.flatMap { displays.firstIndex(of: $0) }.map { $0 + 1 }
        let arguments = Self.arguments(mode: mode, options: options, displayIndex: index, files: files)

        do {
            _ = try await system.capture(arguments: arguments)
        } catch {
            lastError = String(
                localized: "The screenshot couldn't be taken: \(error.localizedDescription)", bundle: .module)
            return .failed
        }

        let captured = files.filter(system.fileExists)
        guard !captured.isEmpty else {
            // Esc in an interactive capture leaves no file behind; that's the user changing their mind.
            if mode.isInteractive { return .cancelled }
            lastError = String(localized: "The screenshot couldn't be taken.", bundle: .module)
            return .failed
        }

        defer { if !keepsCaptures { captured.forEach(system.removeFile) } }
        processCaptures?(mode, captured)
        // All Screens is copied as one image of the whole arrangement, which is what pastes.
        let arrangement = mode == .allScreens && captured.count == displays.count ? displays.map(system.bounds) : nil

        var saved = keepsCaptures ? captured : []
        if let folder = options.destination.folder, combines {
            let file = fileURLs(in: folder, count: 1, options: options, date: date)[0]
            guard let arrangement,
                system.combineImages(
                    captured, arrangedIn: arrangement, into: file, format: options.fileFormat, hdr: options.hdr)
            else {
                lastError = String(localized: "The screens couldn't be combined into one image.", bundle: .module)
                return .failed
            }
            saved = [file]
        }

        if options.destination.copiesToClipboard,
            !system.copyImages(captured, arrangedIn: arrangement, hdr: options.hdr)
        {
            lastError = String(localized: "The screenshot couldn't be copied to the clipboard.", bundle: .module)
            return .failed
        }
        lastSaved = saved
        return saved.isEmpty ? .copied : .saved(saved)
    }

    /// `bounds` are in the global display space, whose origin is the main screen's top left; the
    /// canvas origin is the bottom left.
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
        if options.hdr { arguments.append("-H") }
        arguments += ["-t", options.fileFormat.rawValue]
        arguments += files.map(\.path)
        return arguments
    }

    public func fileURLs(in folder: URL, count: Int, options: ScreenshotOptions, date: Date) -> [URL] {
        let base = "ModeDock \(Self.timestamp(date))"
        let suffixes = count > 1 ? (1...count).map { " (\($0))" } : [""]
        var attempt = 1
        while true {
            let extra = attempt > 1 ? " \(attempt)" : ""
            let urls = suffixes.map {
                folder.appendingPathComponent("\(base)\(extra)\($0).\(options.fileFormat.rawValue)")
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

    public func copyImages(_ files: [URL], arrangedIn bounds: [CGRect]?, hdr: Bool) -> Bool {
        let images = Self.loadImages(files)
        guard !images.isEmpty, images.count == files.count else { return false }
        let image: CGImage
        var heic: Data?
        if let bounds, bounds.count == images.count, images.count > 1 {
            guard let combined = Self.combine(images, bounds: bounds, hdr: hdr) else { return false }
            image = combined
            if hdr { heic = Self.encode(combined, as: .heic) }
        } else {
            image = images[0]
            if hdr { heic = try? Data(contentsOf: files[0]) }
        }
        // From an HDR capture these are 16-bit and keep its colour profile.
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        NSPasteboard.general.clearContents()
        // PNG for apps that take it, TIFF for the ones that only take that, and the HDR HEIC for
        // the few that paste HDR.
        var copied =
            NSPasteboard.general.setData(png, forType: .png)
            && NSPasteboard.general.setData(rep.tiffRepresentation, forType: .tiff)
        if let heic {
            copied = NSPasteboard.general.setData(heic, forType: NSPasteboard.PasteboardType("public.heic")) && copied
        }
        return copied
    }

    public func bounds(of display: CGDirectDisplayID) -> CGRect { CGDisplayBounds(display) }

    public func combineImages(
        _ files: [URL], arrangedIn bounds: [CGRect], into file: URL, format: ScreenshotFormat, hdr: Bool
    ) -> Bool {
        let images = Self.loadImages(files)
        guard images.count == files.count, let image = Self.combine(images, bounds: bounds, hdr: hdr) else {
            return false
        }
        if format == .pdf {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let context = CGContext(file as CFURL, mediaBox: &box, nil) else { return false }
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
            context.closePDF()
            return true
        }
        guard
            let destination = CGImageDestinationCreateWithURL(file as CFURL, format.type.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func encode(_ image: CGImage, as format: ScreenshotFormat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func loadImages(_ files: [URL]) -> [CGImage] {
        files.compactMap { url in
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            {
                return image
            }
            return renderPDF(url)
        }
    }

    /// ImageIO can't read PDFs. screencapture's page is in points around a full-resolution
    /// bitmap, so the page is drawn at that bitmap's size to keep Retina detail.
    private static func renderPDF(_ url: URL) -> CGImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = widestImage(on: page).map { max(CGFloat($0) / box.width, 1) } ?? 1
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: Int((box.width * scale).rounded()), height: Int((box.height * scale).rounded()),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func widestImage(on page: CGPDFPage) -> Int? {
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
            let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects
        else { return nil }
        var widest = 0
        CGPDFDictionaryApplyBlock(
            objects,
            { _, object, _ in
                var stream: CGPDFStreamRef?
                var width: CGPDFInteger = 0
                if CGPDFObjectGetValue(object, .stream, &stream), let stream,
                    let info = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetInteger(info, "Width", &width)
                {
                    widest = max(widest, width)
                }
                return true
            }, nil)
        return widest > 0 ? widest : nil
    }

    /// Drawn at the sharpest screen's scale so Retina detail is kept. HDR captures are drawn at
    /// 16 bits in their own colour space.
    private static func combine(_ images: [CGImage], bounds: [CGRect], hdr: Bool) -> CGImage? {
        let scale = zip(images, bounds).map { CGFloat($0.width) / max($1.width, 1) }.max() ?? 1
        let layout = ScreenshotController.arrangement(of: bounds, scale: scale)
        let space =
            hdr
            ? images.first?.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)
            : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
            let context = CGContext(
                data: nil, width: Int(layout.size.width.rounded()), height: Int(layout.size.height.rounded()),
                bitsPerComponent: hdr ? 16 : 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | (hdr ? CGBitmapInfo.byteOrder16Little.rawValue : 0))
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
