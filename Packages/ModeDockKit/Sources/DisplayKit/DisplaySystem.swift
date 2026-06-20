import AppKit
import CoreGraphics
import Foundation
import PrivateAPI

public enum DisplayError: Error, Equatable, LocalizedError {
    case unsupported
    case wouldDisableLastDisplay
    case modeUnavailable
    case coreGraphics(Int32)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: "This version of macOS can't turn screens off."
        case .wouldDisableLastDisplay: "At least one screen has to stay on."
        case .modeUnavailable: "That resolution isn't available on this screen anymore."
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
                isEnabled: CGDisplayIsActive(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay,
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
        guard try PMSet.run("displaysleepnow") else { throw DisplayError.commandFailed("pmset displaysleepnow") }
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

/// Which private APIs this macOS version provides.
public enum DisplayCapabilities {
    public static var canDisableDisplays: Bool { PrivateAPI.configureDisplayEnabled != nil }
    public static var canUseDDC: Bool {
        PrivateAPI.avServiceCreateWithService != nil && PrivateAPI.avServiceWriteI2C != nil
            && PrivateAPI.avServiceReadI2C != nil
    }
}
