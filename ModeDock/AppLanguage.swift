import AppKit

/// macOS picks an app's language at launch from AppleLanguages, so a change needs a restart.
enum AppLanguage {
    static let system = "system"

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

    static var running: String? { Bundle.main.preferredLocalizations.first }

    static func apply() {
        let defaults = UserDefaults.standard
        if current == system {
            defaults.removeObject(forKey: appleLanguages)
        } else {
            defaults.set([current], forKey: appleLanguages)
        }
    }

    static var needsRestart: Bool {
        let wanted = current == system ? Bundle.main.preferredLocalizations(fromSystem: true) : current
        return wanted != running
    }

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
    fileprivate func preferredLocalizations(fromSystem: Bool) -> String? {
        let system =
            (UserDefaults(suiteName: UserDefaults.globalDomain)?.array(forKey: "AppleLanguages") as? [String])
            ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from: localizations, forPreferences: system).first
    }
}
