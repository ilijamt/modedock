import AppKit

/// ModeDock's own language, independent of the system's. macOS picks an app's language at
/// launch from AppleLanguages, so a change takes effect after a restart. The choices are the
/// languages the app was built with, so adding one to the string catalogs adds it here.
enum AppLanguage {
    static let system = "system"

    /// "system", then every language the app has, by its name in that language.
    static var choices: [String] {
        let languages = Bundle.main.localizations.filter { $0 != "Base" }
        return [system] + languages.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    /// Each language in its own name, so people can find theirs whatever ModeDock shows now.
    static func name(of code: String) -> String {
        if code == system { return String(localized: "System") }
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: Locale(identifier: code)) + name.dropFirst()
    }

    static let key = "appLanguage"
    private static let appleLanguages = "AppleLanguages"

    static var current: String {
        UserDefaults.standard.string(forKey: key).flatMap { choices.contains($0) ? $0 : nil } ?? system
    }

    /// The language ModeDock is showing now, which a restart would change.
    static var running: String? { Bundle.main.preferredLocalizations.first }

    /// Writes the choice where macOS reads it at the next launch.
    static func apply() {
        let defaults = UserDefaults.standard
        if current == system {
            defaults.removeObject(forKey: appleLanguages)
        } else {
            defaults.set([current], forKey: appleLanguages)
        }
    }

    /// Whether the chosen language differs from the one ModeDock started with.
    static var needsRestart: Bool {
        let wanted = current == system ? Bundle.main.preferredLocalizations(fromSystem: true) : current
        return wanted != running
    }

    /// Quits and opens ModeDock again, so the new language loads.
    @MainActor
    static func restart() {
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for this instance to quit before opening a new one.
        relaunch.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"\(path)\"",
        ]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}

extension Bundle {
    /// The best match for the system's own language list among ModeDock's languages.
    fileprivate func preferredLocalizations(fromSystem: Bool) -> String? {
        let system =
            (UserDefaults(suiteName: UserDefaults.globalDomain)?.array(forKey: "AppleLanguages") as? [String])
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: localizations, forPreferences: system).first
    }
}
