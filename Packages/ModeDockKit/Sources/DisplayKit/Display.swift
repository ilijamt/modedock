import CoreGraphics

/// Vendor, model and serial from the EDID. Unlike `CGDirectDisplayID`, this survives
/// reconnects and reboots.
public struct DisplayIdentity: Hashable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    /// macOS adds a placeholder display with an unknown vendor when no real screen is connected.
    public var isPlaceholder: Bool {
        vendor == 0 || vendor == 0x756E_6B6E || vendor == 0xFFFF_FFFF  // 0x756E6B6E is 'unkn'
    }

    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

public struct Display: Identifiable, Hashable, Sendable {
    public let id: CGDirectDisplayID
    public let identity: DisplayIdentity
    public var name: String
    public let isBuiltin: Bool
    /// False while ModeDock has the display disabled.
    public var isEnabled: Bool

    public init(
        id: CGDirectDisplayID,
        identity: DisplayIdentity,
        name: String,
        isBuiltin: Bool,
        isEnabled: Bool
    ) {
        self.id = id
        self.identity = identity
        self.name = name
        self.isBuiltin = isBuiltin
        self.isEnabled = isEnabled
    }
}

public enum DisplayPolicy {
    /// A display may be disabled only if at least one other display stays enabled.
    public static func canDisable(_ id: CGDirectDisplayID, enabled: Set<CGDirectDisplayID>) -> Bool {
        enabled.contains(id) && enabled.count > 1
    }
}
