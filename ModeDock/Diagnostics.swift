import AppKit
import DisplayKit
import ModeDockCore

/// A plain-text report for bug reports. It has no personal data beyond display models.
@MainActor
enum Diagnostics {
    static func report(screens: ScreenController, modes: DisplayModeController) -> String {
        var lines = [
            "ModeDock \(Bundle.main.versionString)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Private APIs: display enable=\(DisplayCapabilities.canDisableDisplays), DDC=\(DisplayCapabilities.canUseDDC)",
            "Mirroring: \(modes.isMirroring)",
            "",
        ]
        for screen in screens.screens {
            let display = screen.display
            let identity = display.identity
            lines.append("\(display.name) [id \(display.id)]")
            lines.append(
                "  vendor \(identity.vendor) model \(identity.model) hasSerial=\(identity.serial != 0) "
                    + "builtin=\(display.isBuiltin)"
            )
            lines.append(
                "  on=\(display.isEnabled) ddc=\(screen.supportsDDC) standby=\(screen.isInStandby)")
            if let screenModes = modes.screens[display.id] {
                let current = screenModes.current.map {
                    "\($0.width)x\($0.height) px \($0.pixelWidth)x\($0.pixelHeight) \($0.refreshRate) Hz id \($0.id)"
                }
                lines.append("  main=\(screenModes.isMain) mode \(current ?? "?") options \(screenModes.options.count)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func copy(screens: ScreenController, modes: DisplayModeController) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(screens: screens, modes: modes), forType: .string)
    }
}

extension Bundle {
    /// "0.1.0 (1)": the marketing version and the build number.
    var versionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
