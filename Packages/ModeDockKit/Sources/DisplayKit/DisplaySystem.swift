import AppKit
import CoreGraphics
import Foundation
import PrivateAPI

public enum DisplayError: Error, Equatable, LocalizedError {
    case unsupported
    case wouldDisableLastDisplay
    case coreGraphics(Int32)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This version of macOS can't turn screens off."
        case .wouldDisableLastDisplay: "At least one screen has to stay on."
        case .coreGraphics(let code): "macOS couldn't change the screen (error \(code))."
        case .commandFailed(let command): "\(command) failed."
        }
    }
}

/// Talks to CoreGraphics. Abstracted so the controller can be tested without real displays.
@MainActor
public protocol DisplaySystem {
    func onlineDisplays() -> [Display]
    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws
    func sleepAllDisplays() throws
}

@MainActor
public struct CoreGraphicsDisplaySystem: DisplaySystem {
    public init() {}

    public func onlineDisplays() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let names = Self.screenNames()
        return ids.prefix(Int(count)).map { id in
            Display(
                id: id,
                identity: DisplayIdentity(
                    vendor: CGDisplayVendorNumber(id),
                    model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id)
                ),
                name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isEnabled: CGDisplayIsActive(id) != 0,
                isMain: CGDisplayIsMain(id) != 0
            )
        }
    }

    public func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        guard let configure = PrivateAPI.configureDisplayEnabled else { throw DisplayError.unsupported }
        var config: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&config)
        guard result == .success else { throw DisplayError.coreGraphics(result.rawValue) }
        result = configure(config, display, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.coreGraphics(result.rawValue)
        }
        // forSession: a display left disabled comes back after logout or reboot.
        result = CGCompleteDisplayConfiguration(config, .forSession)
        guard result == .success else { throw DisplayError.coreGraphics(result.rawValue) }
    }

    public func sleepAllDisplays() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DisplayError.commandFailed("pmset displaysleepnow") }
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return Dictionary(
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[key] as? NSNumber).map { ($0.uint32Value, screen.localizedName) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
