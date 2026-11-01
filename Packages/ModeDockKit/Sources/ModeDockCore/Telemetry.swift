import Foundation
import Observation

/// The features telemetry counts. The raw values are the names the server sees, so they never
/// change once released; add new cases instead.
public enum TelemetryEvent: String, CaseIterable, Codable, Sendable {
    case panelOpened = "panel.opened"
    case settingsOpened = "settings.opened"

    case screenToggled = "screen.toggled"
    case screenStandby = "screen.standby"
    case screenBrightness = "screen.brightness"
    case screenResolution = "screen.resolution"
    case screenMirroring = "screen.mirroring"
    case screenMain = "screen.main"
    case screensSlept = "screen.sleep"
    case screensAllOn = "screen.allOn"
    case screenInput = "screen.input"

    case profileSaved = "profile.saved"
    case profileApplied = "profile.applied"
    case profileAutoApplied = "profile.autoApplied"
    case profileSwitcher = "profile.switcher"

    case keepAwake = "power.keepAwake"
    case macSlept = "power.sleep"
    case screenLocked = "power.lock"

    case darkMode = "utility.darkMode"
    case nightShift = "utility.nightShift"
    case trueTone = "utility.trueTone"
    case dockAutoHide = "utility.dockAutoHide"
    case desktopIcons = "utility.desktopIcons"
    case hiddenFiles = "utility.hiddenFiles"
    case trashEmptied = "utility.emptyTrash"
    case disksEjected = "utility.eject"

    case captureArea = "capture.area"
    case captureWindow = "capture.window"
    case captureScreen = "capture.screen"
    case captureAllScreens = "capture.allScreens"

    case brightnessKeys = "screen.brightnessKeys"

    case configurationExported = "config.exported"
    case configurationImported = "config.imported"

    /// Where an action came from: the native menu style or a shortcut. The panel is the rest.
    case menuUsed = "source.menu"
    case shortcutUsed = "source.shortcut"
    /// A tab chosen in the panel, with the section as its detail.
    case panelTab = "panel.tab"
    /// Each press of Next Profile after the switcher opened.
    case profileSwitcherStep = "profile.switcherStep"
    case resolutionKept = "screen.resolutionKept"
    case resolutionReverted = "screen.resolutionReverted"

    // Errors by kind only, never their text.
    case errorScreen = "error.screen"
    case errorResolution = "error.resolution"
    case errorBrightness = "error.brightness"
    case errorInput = "error.input"
    case errorCapture = "error.capture"
    case errorUtility = "error.utility"
    case errorProfile = "error.profile"
}

/// How this install is set up, sent with each report. Only counts, on/off flags and choices from
/// fixed lists; no names, models, paths or keys.
public struct TelemetrySetup: Codable, Equatable, Sendable {
    public var profiles = 0
    public var automaticProfiles = 0
    public var profilesWithSystemSettings = 0
    public var shortcuts = 0
    public var profileShortcuts = 0
    public var macCaptureKeys = false
    public var brightnessKeysAllScreens = false
    public var externalScreens = 0
    public var ddcScreens = 0
    public var laptop = false
    public var showAllResolutions = false
    public var showStandby = false
    public var ddcWriteInterval = 0
    public var panelStyle = ""
    /// Empty with the menu style, which has no layout.
    public var panelLayout = ""
    public var hiddenSections: [String] = []
    /// The hidden panel items by section, from the fixed list of items: ["power": ["battery"]].
    public var hiddenItemsBySection: [String: [String]] = [:]
    public var captureDestination = ""
    public var captureFormat = ""
    public var captureHDR = false
    public var captureOneImage = true
    public var captureTimer = 0
    public var capturePreview = true
    public var capturePointer = false
    public var capturePointerEverywhere = false
    /// 0 for "until turned off".
    public var keepAwakeMinutes = 0
    public var keepAwakeScreensOn = true
    /// The choice in Settings: "system" or a language code. context.language is the one shown.
    public var languageSetting = ""
    public var appearance = ""
    public var launchAtLogin = false
    public var debugLogging = false
    /// Days since opting in: "0-7", "8-30", "31-90" or "90+".
    public var optedIn = ""

    public init() {}
}

/// Broad facts sent with the counts, for the dashboard. Nothing here identifies a person or a Mac.
public struct TelemetryContext: Codable, Equatable, Sendable {
    public var appVersion: String
    /// Major and minor only, e.g. "26.1".
    public var osVersion: String
    /// The language ModeDock shows.
    public var language: String

    public init(appVersion: String, osVersion: String, language: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.language = language
    }
}

/// What's sent: one report per install with the counts of each complete day.
public struct TelemetryReport: Codable, Equatable, Sendable {
    public var schema = 1
    /// Random, made when the user opts in and deleted when they opt out.
    public var install: UUID
    public var context: TelemetryContext
    public var setup: TelemetrySetup?
    /// Day ("2026-11-15", UTC) → feature name → count.
    public var days: [String: [String: Int]]
}

/// Sends a report; abstracted for tests.
public protocol TelemetrySender: Sendable {
    func send(_ report: TelemetryReport, to url: URL) async -> Bool
}

public struct HTTPTelemetrySender: TelemetrySender {
    public init() {}

    public func send(_ report: TelemetryReport, to url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No cookies or caches: nothing ties one report to another but the install ID.
        let session = URLSession(configuration: .ephemeral)
        guard let body = try? JSONEncoder().encode(report) else { return false }
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}

/// Opt-in, anonymous usage counts. Off until the user turns it on; nothing is sent until an
/// endpoint is configured, and then only whole days, about once a day.
@MainActor
@Observable
public final class Telemetry {
    public static let shared = Telemetry()

    /// Where reports go. Set when the server exists; until then counts stay on this Mac.
    public static let endpoint: URL? = nil

    /// Days kept on this Mac when they can't be sent, so the store stays small.
    static let maxDays = 30

    private enum Key {
        static let enabled = "telemetry.enabled"
        static let install = "telemetry.install"
        static let counts = "telemetry.counts"
        static let lastAttempt = "telemetry.lastAttempt"
        static let since = "telemetry.since"
    }

    private let defaults: UserDefaults
    private let sender: TelemetrySender
    private let endpointOverride: URL?
    private let now: () -> Date

    public private(set) var isEnabled: Bool

    public init(
        defaults: UserDefaults = .standard, sender: TelemetrySender = HTTPTelemetrySender(), endpoint: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.sender = sender
        self.endpointOverride = endpoint
        self.now = now
        isEnabled = defaults.bool(forKey: Key.enabled)
    }

    private var endpoint: URL? { endpointOverride ?? Self.endpoint }

    /// Turning it off deletes the install ID and every count kept so far.
    public func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Key.enabled)
        if on {
            if defaults.string(forKey: Key.install) == nil {
                defaults.set(UUID().uuidString, forKey: Key.install)
                defaults.set(now(), forKey: Key.since)
            }
        } else {
            for key in [Key.install, Key.counts, Key.lastAttempt, Key.since] { defaults.removeObject(forKey: key) }
        }
    }

    public func record(_ event: TelemetryEvent) {
        count(event.rawValue)
    }

    /// Counts "event.detail". The detail must come from a fixed list, such as a section or a
    /// configuration part, never from anything the user typed.
    public func record(_ event: TelemetryEvent, detail: String) {
        count("\(event.rawValue).\(detail)")
    }

    /// "0-7", "8-30", "31-90" or "90+" days since opting in; empty when off.
    public var optedInBucket: String {
        guard let since = defaults.object(forKey: Key.since) as? Date else { return "" }
        let days = Int(now().timeIntervalSince(since) / 86_400)
        return switch days {
        case ..<8: "0-7"
        case ..<31: "8-30"
        case ..<91: "31-90"
        default: "90+"
        }
    }

    private func count(_ name: String) {
        guard isEnabled else { return }
        var counts = storedCounts
        let day = Self.day(now())
        counts[day, default: [:]][name, default: 0] += 1
        // Drop the oldest days beyond the limit.
        for old in counts.keys.sorted().dropLast(Self.maxDays) { counts.removeValue(forKey: old) }
        storedCounts = counts
    }

    /// The report as it would be sent now, for Settings → Show Data; nil when off.
    public func preview(context: TelemetryContext, setup: TelemetrySetup? = nil) -> TelemetryReport? {
        guard isEnabled, let install = installID else { return nil }
        return TelemetryReport(install: install, context: context, setup: setup, days: storedCounts)
    }

    /// Sends the complete days (not today) and forgets them once the server accepted them.
    /// Does nothing when off, without an endpoint, or when it already tried in the last 20 hours.
    @discardableResult
    public func sendIfDue(context: TelemetryContext, setup: TelemetrySetup? = nil) async -> Bool {
        guard isEnabled, let endpoint, let install = installID else { return false }
        if let last = defaults.object(forKey: Key.lastAttempt) as? Date, now().timeIntervalSince(last) < 20 * 3600 {
            return false
        }
        let today = Self.day(now())
        let complete = storedCounts.filter { $0.key < today }
        guard !complete.isEmpty else { return false }
        defaults.set(now(), forKey: Key.lastAttempt)
        let report = TelemetryReport(install: install, context: context, setup: setup, days: complete)
        let sent = await sender.send(report, to: endpoint)
        if sent {
            var counts = storedCounts
            for day in complete.keys { counts.removeValue(forKey: day) }
            storedCounts = counts
        }
        return sent
    }

    private var installID: UUID? { defaults.string(forKey: Key.install).flatMap(UUID.init(uuidString:)) }

    private var storedCounts: [String: [String: Int]] {
        get { defaults.dictionary(forKey: Key.counts) as? [String: [String: Int]] ?? [:] }
        set { defaults.set(newValue, forKey: Key.counts) }
    }

    /// "2026-11-15" in UTC, so a day means the same everywhere.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
