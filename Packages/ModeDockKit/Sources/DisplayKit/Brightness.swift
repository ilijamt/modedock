import CoreGraphics
import PrivateAPI

/// How a screen's brightness is controlled.
public enum BrightnessBackend: Equatable, Sendable {
    /// DisplayServices: built-in and Apple displays.
    case system
    /// The monitor's own backlight over DDC.
    case ddc(maximum: UInt16)
    /// Gamma dimming for screens with neither; it dims the image, not the backlight.
    case software
}

/// Brightness through DisplayServices and gamma tables. Abstracted for tests.
@MainActor
public protocol BrightnessSystem {
    func canControl(_ display: CGDirectDisplayID) -> Bool
    /// 0...1, or nil when it can't be read.
    func brightness(of display: CGDirectDisplayID) -> Double?
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) throws
    /// 1 removes the dimming.
    func setSoftwareDimming(_ value: Double, of display: CGDirectDisplayID)
    /// Restores every display's normal colours.
    func resetSoftwareDimming()
    /// nil when the display has no light sensor.
    func autoBrightness(of display: CGDirectDisplayID) -> Bool?
    func setAutoBrightness(_ enabled: Bool, of display: CGDirectDisplayID) throws
}

@MainActor
public struct CoreBrightnessSystem: BrightnessSystem {
    public init() {}

    public func canControl(_ display: CGDirectDisplayID) -> Bool {
        PrivateAPI.canChangeBrightness?(display) ?? false
    }

    public func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let get = PrivateAPI.getBrightness else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? Double(value) : nil
    }

    public func setBrightness(_ value: Double, of display: CGDirectDisplayID) throws {
        guard let set = PrivateAPI.setBrightness else { throw DisplayError.unsupported }
        let result = set(display, Float(value))
        guard result == 0 else { throw DisplayError.coreGraphics(result) }
    }

    public func setSoftwareDimming(_ value: Double, of display: CGDirectDisplayID) {
        let max = CGGammaValue(value)
        CGSetDisplayTransferByFormula(display, 0, max, 1, 0, max, 1, 0, max, 1)
    }

    public func resetSoftwareDimming() {
        CGDisplayRestoreColorSyncSettings()
    }

    public func autoBrightness(of display: CGDirectDisplayID) -> Bool? {
        guard PrivateAPI.hasAutoBrightness?(display) == true, let get = PrivateAPI.autoBrightnessEnabled else {
            return nil
        }
        var enabled = false
        return get(display, &enabled) == 0 ? enabled : nil
    }

    public func setAutoBrightness(_ enabled: Bool, of display: CGDirectDisplayID) throws {
        guard let set = PrivateAPI.setAutoBrightness else { throw DisplayError.unsupported }
        let result = set(display, enabled)
        guard result == 0 else { throw DisplayError.coreGraphics(result) }
    }
}
