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
        case .unsupported: String(localized: "This version of macOS can't turn screens off.", bundle: .module)
        case .wouldDisableLastDisplay: String(localized: "At least one screen has to stay on.", bundle: .module)
        case .modeUnavailable:
            String(localized: "That resolution isn't available on this screen anymore.", bundle: .module)
        case .coreGraphics(let code):
            String(localized: "macOS couldn't change the screen (error \(code)).", bundle: .module)
        case .commandFailed(let command): String(localized: "\(command) failed.", bundle: .module)
        }
    }
}

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
                name: names[id]
                    ?? (CGDisplayIsBuiltin(id) != 0
                        ? String(localized: "Built-in Display", bundle: .module)
                        : String(localized: "Display \(id)", bundle: .module)),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isEnabled: CGDisplayIsActive(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            )
        }
    }

    public func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        guard let configure = PrivateAPI.configureDisplayEnabled else { throw DisplayError.unsupported }
        // forSession: a display left disabled comes back after logout or reboot.
        try configureDisplays(.forSession) { configure($0, display, enabled) }
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

public enum DisplayCapabilities {
    public static var canDisableDisplays: Bool { PrivateAPI.configureDisplayEnabled != nil }
    public static var canUseDDC: Bool {
        PrivateAPI.avServiceCreateWithService != nil && PrivateAPI.avServiceWriteI2C != nil
            && PrivateAPI.avServiceReadI2C != nil
    }
}
