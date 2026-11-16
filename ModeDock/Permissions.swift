import AppKit
import ApplicationServices

enum PermissionStatus: Sendable {
    case allowed, denied, notAsked
}

/// Empty Trash asks Finder over Apple Events, which needs the Automation permission.
enum FinderAutomation {
    private static let bundleID = "com.apple.finder"

    /// Asking blocks until the user answers, so call it off the main thread. Finder has to be
    /// running, which it nearly always is; otherwise this reports `.notAsked`.
    static func status(askIfNeeded: Bool = false) -> PermissionStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else { return .notAsked }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askIfNeeded) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notAsked
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
