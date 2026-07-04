import AppKit
import CoreGraphics
import Foundation
import Observation

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

public enum ScreenshotDestination: Equatable, Sendable {
    case folder(URL)
    case clipboard
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

    public init(
        destination: ScreenshotDestination, format: ScreenshotFormat = .png, includePointer: Bool = false,
        playSound: Bool = true, windowShadow: Bool = true, delay: Int = 0
    ) {
        self.destination = destination
        self.format = format
        self.includePointer = includePointer
        self.playSound = playSound
        self.windowShadow = windowShadow
        self.delay = delay
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
    func pasteboardChangeCount() -> Int
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
    /// The files the last capture saved; empty after a clipboard capture.
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

        let displays = system.activeDisplays()
        var files: [URL] = []
        if case .folder(let folder) = options.destination {
            files = fileURLs(
                in: folder, count: mode == .allScreens ? max(displays.count, 1) : 1, options: options, date: date)
        } else if mode == .allScreens {
            lastError = "All Screens can only save to a folder. Choose a folder in Settings → Screenshots."
            return .failed
        }
        let index = display.flatMap { displays.firstIndex(of: $0) }.map { $0 + 1 }
        let arguments = Self.arguments(mode: mode, options: options, displayIndex: index, files: files)

        let changeCount = system.pasteboardChangeCount()
        let status: Int32
        do {
            status = try await system.capture(arguments: arguments)
        } catch {
            lastError = "The screenshot couldn't be taken: \(error.localizedDescription)"
            return .failed
        }

        let saved = files.filter(system.fileExists)
        let succeeded =
            options.destination == .clipboard
            ? status == 0 && system.pasteboardChangeCount() != changeCount : !saved.isEmpty
        if succeeded {
            lastSaved = saved
            return options.destination == .clipboard ? .copied : .saved(saved)
        }
        // Esc in an interactive capture leaves no file behind; that's the user changing their mind.
        if mode.isInteractive { return .cancelled }
        lastError = "The screenshot couldn't be taken."
        return .failed
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
        if options.destination == .clipboard { arguments.append("-c") }
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

    public func pasteboardChangeCount() -> Int { NSPasteboard.general.changeCount }

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
