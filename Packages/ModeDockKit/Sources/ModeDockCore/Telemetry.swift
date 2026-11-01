import Foundation
import Observation

/// The features telemetry counts. The raw values are the names the server sees, so they never
/// change once released; add new cases instead.
public enum TelemetryEvent: String, CaseIterable, Codable, Sendable {
    case appLaunch = "app.launch"
    /// 1 on each day ModeDock ran, used or not: the base for every share of active installs.
    case appActive = "app.active"

    case panelOpen = "panel.open"
    case settingsOpen = "settings.open"

    case screenToggle = "screen.toggle"
    case screenStandby = "screen.standby"
    case screenBrightness = "screen.brightness"
    case screenResolution = "screen.resolution"
    case screenMirroring = "screen.mirroring"
    case screenMain = "screen.main"
    case screensSleep = "screen.sleep"
    case screensAllOn = "screen.allOn"
    case screenInput = "screen.input"

    case profileSave = "profile.save"
    case profileApply = "profile.apply"
    case profileAutoApply = "profile.autoApply"
    case profileSwitcher = "profile.switcher"

    case keepAwake = "power.keepAwake"
    case macSleep = "power.sleep"
    case screenLock = "power.lock"

    case darkMode = "utility.darkMode"
    case nightShift = "utility.nightShift"
    case trueTone = "utility.trueTone"
    case dockAutoHide = "utility.dockAutoHide"
    case desktopIcons = "utility.desktopIcons"
    case hiddenFiles = "utility.hiddenFiles"
    case emptyTrash = "utility.emptyTrash"
    case ejectDisks = "utility.eject"

    case captureArea = "capture.area"
    case captureWindow = "capture.window"
    case captureScreen = "capture.screen"
    case captureAllScreens = "capture.allScreens"

    case brightnessKeys = "screen.brightnessKeys"

    case configExport = "config.export"
    case configImport = "config.import"

    /// Where an action came from: the native menu style or a shortcut. The panel is the rest.
    case sourceMenu = "source.menu"
    /// Counted in total and per shortcut, as source.shortcut.<name>.
    case sourceShortcut = "source.shortcut"
    /// A tab chosen in the panel, with the section as its detail.
    case panelTab = "panel.tab"
    /// Each press of Next Profile after the switcher opened.
    case profileSwitcherStep = "profile.switcherStep"
    case resolutionKeep = "screen.resolutionKeep"
    case resolutionRevert = "screen.resolutionRevert"

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
    /// "arm64" or "x86_64".
    public var architecture: String

    public init(appVersion: String, osVersion: String, language: String, architecture: String = Self.architecture) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.language = language
        self.architecture = architecture
    }

    public static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }
}

/// What's sent: the counts since the last report the server accepted. The server dates it on
/// arrival and adds it to the install's totals.
public struct TelemetryReport: Codable, Equatable, Sendable {
    public var schema = 1
    /// Random, made when the user opts in and deleted when they opt out.
    public var install: UUID
    /// Random per batch and kept until the server accepts it, so a resent batch (after a lost
    /// reply) replaces the first copy instead of being counted twice. A retry carries the same ID
    /// with everything counted since, so the newest copy is always the complete one.
    public var report: UUID
    public var context: TelemetryContext
    public var setup: TelemetrySetup?
    /// Feature name → count since the last accepted report.
    public var counts: [String: Int]
}

/// Sends a report; abstracted for tests.
public protocol TelemetrySender: Sendable {
    func send(_ report: TelemetryReport, to url: URL) async -> Bool
}

public struct HTTPTelemetrySender: TelemetrySender {
    private let configuration: @Sendable () -> URLSessionConfiguration

    /// Ephemeral by default: no cookies or caches, so nothing ties one report to another but the
    /// install ID. Tests pass one with a fake server.
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configuration = configuration
    }

    public func send(_ report: TelemetryReport, to url: URL) async -> Bool {
        guard let body = try? JSONEncoder().encode(report) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = URLSession(configuration: configuration())
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}

/// Opt-in, anonymous usage counts. Off until the user turns it on; nothing is sent until an
/// endpoint is configured, and then about every 8 hours.
@MainActor
@Observable
public final class Telemetry {
    public static let shared = Telemetry()

    /// Where reports go. Set when the server exists; until then counts stay on this Mac.
    public static let endpoint: URL? = nil

    /// The least time between reports, including failed ones. About three a day: often enough
    /// to see when in the day features are used, but no closer to when the Mac is on.
    public static let interval: TimeInterval = 8 * 3600

    /// What people agree to. Raise it when a release starts collecting something new, so
    /// everyone is asked once more; ordinary updates never ask.
    public static let consentVersion = 1

    private enum Key {
        static let enabled = "telemetry.enabled"
        static let install = "telemetry.install"
        static let counts = "telemetry.counts"
        static let report = "telemetry.report"
        static let activeDay = "telemetry.activeDay"
        static let lastAttempt = "telemetry.lastAttempt"
        static let since = "telemetry.since"
        /// The consent version last answered, by the question or the switch in Settings.
        static let asked = "telemetry.askedVersion"
        /// Debug builds only: a local test server.
        static let debugEndpoint = "telemetry.endpoint"
    }

    private let defaults: UserDefaults
    private let sender: TelemetrySender
    private let endpointOverride: URL?
    private let now: () -> Date

    public private(set) var isEnabled: Bool
    /// One report at a time, so the same counts are never taken off twice.
    private var isSending = false

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

    /// Where reports go now: a test server in debug builds when one is set, otherwise the real one.
    public var endpoint: URL? {
        #if DEBUG
            if let debug = defaults.string(forKey: Key.debugEndpoint).flatMap(URL.init(string:)) {
                return endpointOverride ?? debug
            }
        #endif
        return endpointOverride ?? Self.endpoint
    }

    /// Whether to ask: on a new install, and after `consentVersion` went up.
    public var shouldAsk: Bool { defaults.integer(forKey: Key.asked) < Self.consentVersion }

    /// Turning it off deletes the install ID and every count kept so far.
    public func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: Key.enabled)
        defaults.set(Self.consentVersion, forKey: Key.asked)
        if on {
            if defaults.string(forKey: Key.install) == nil {
                defaults.set(UUID().uuidString, forKey: Key.install)
                defaults.set(now(), forKey: Key.since)
            }
        } else {
            for key in [Key.install, Key.counts, Key.report, Key.activeDay, Key.lastAttempt, Key.since] {
                defaults.removeObject(forKey: key)
            }
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

    /// A shortcut press, in total and by name. The name must come from the app's fixed list:
    /// shortcuts named after a profile or a screen are passed as "profile" or "toggleScreen".
    public func recordShortcut(_ name: String) {
        record(.sourceShortcut)
        record(.sourceShortcut, detail: name)
    }

    /// Counts today as a day ModeDock ran, once per day.
    public func markActive() {
        guard isEnabled else { return }
        let day = Self.day(now())
        guard defaults.string(forKey: Key.activeDay) != day else { return }
        defaults.set(day, forKey: Key.activeDay)
        add(TelemetryEvent.appActive.rawValue)
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
        markActive()
        add(name)
    }

    private func add(_ name: String) {
        var counts = storedCounts
        counts[name, default: 0] += 1
        storedCounts = counts
    }

    /// The report as it would be sent now, for Settings → Show Data; nil when off.
    public func preview(context: TelemetryContext, setup: TelemetrySetup? = nil) -> TelemetryReport? {
        guard isEnabled, let install = installID else { return nil }
        return TelemetryReport(
            install: install, report: reportID, context: context, setup: setup, counts: storedCounts)
    }

    /// Sends the counts since the last accepted report. Does nothing when off, without an
    /// endpoint, with nothing counted, or when it tried less than `interval` ago.
    @discardableResult
    public func sendIfDue(context: TelemetryContext, setup: TelemetrySetup? = nil) async -> Bool {
        if let last = defaults.object(forKey: Key.lastAttempt) as? Date, now().timeIntervalSince(last) < Self.interval {
            return false
        }
        return await sendNow(context: context, setup: setup)
    }

    /// Sends without waiting; for testing against a server. Counts made while sending are kept.
    @discardableResult
    public func sendNow(context: TelemetryContext, setup: TelemetrySetup? = nil) async -> Bool {
        guard isEnabled, !isSending, let endpoint, let install = installID else { return false }
        let counts = storedCounts
        guard !counts.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        defaults.set(now(), forKey: Key.lastAttempt)
        let id = reportID
        let report = TelemetryReport(install: install, report: id, context: context, setup: setup, counts: counts)
        // Turned off, or off and on again, while sending: the counts now belong to another install.
        guard await sender.send(report, to: endpoint), installID == install else { return false }
        // Only what was sent is taken off, and the next batch gets a new ID.
        var remaining = storedCounts
        for (name, sent) in counts {
            let left = (remaining[name] ?? 0) - sent
            remaining[name] = left > 0 ? left : nil
        }
        storedCounts = remaining
        defaults.removeObject(forKey: Key.report)
        return true
    }

    private var installID: UUID? { defaults.string(forKey: Key.install).flatMap(UUID.init(uuidString:)) }

    /// The current batch's ID, made when first needed.
    private var reportID: UUID {
        if let id = defaults.string(forKey: Key.report).flatMap(UUID.init(uuidString:)) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Key.report)
        return id
    }

    private var storedCounts: [String: Int] {
        get { defaults.dictionary(forKey: Key.counts) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Key.counts) }
    }

    /// The local calendar day, only to count each day once.
    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
