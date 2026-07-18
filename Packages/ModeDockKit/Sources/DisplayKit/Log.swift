import Foundation
import os

/// ModeDock's log: always the system log, and with debug logging on, also a file that can be
/// attached to a bug report. macOS doesn't keep debug messages, so the file is the only record
/// of them. Messages must never contain serial numbers.
public struct AppLog: Sendable {
    public static let screens = AppLog("screens")

    private let category: String
    private let logger: Logger

    public init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "com.matoski.modedock", category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        LogFile.write("DEBUG", category, message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        LogFile.write("INFO", category, message)
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        LogFile.write("NOTICE", category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        LogFile.write("ERROR", category, message)
    }
}

/// ~/Library/Logs/ModeDock/ModeDock.log, written only while debug logging is on. It's moved to
/// ModeDock.1.log when it passes 2 MB, so at most two files are kept.
public enum LogFile {
    public static let enabledKey = "debugLogging"
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ModeDock/ModeDock.log")
    private static let previousURL = url.deletingPathExtension().appendingPathExtension("1.log")
    private static let maxSize = 2_000_000
    private static let queue = DispatchQueue(label: "com.matoski.modedock.logfile")

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func write(_ level: String, _ category: String, _ message: String) {
        guard isEnabled else { return }
        let time = Date.now.ISO8601Format(.iso8601(timeZone: .current, includingFractionalSeconds: true))
        let line = "\(time) \(level) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// The previous file, then the current one.
    public static func contents() -> String {
        queue.sync {
            [previousURL, url].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        }
    }

    public static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    private static func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
            try? manager.removeItem(at: previousURL)
            try? manager.moveItem(at: url, to: previousURL)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
