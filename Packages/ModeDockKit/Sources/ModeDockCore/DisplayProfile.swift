import CoreGraphics
import DisplayKit
import Foundation

/// A saved screen setup: which screens are on, their resolutions, arrangement and brightness.
public struct DisplayProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Applied by itself when exactly this set of screens is connected.
    public var autoApply: Bool
    public var mirroring: Bool
    public var screens: [ProfileScreen]

    public init(
        id: UUID = UUID(), name: String, autoApply: Bool = false, mirroring: Bool = false,
        screens: [ProfileScreen]
    ) {
        self.id = id
        self.name = name
        self.autoApply = autoApply
        self.mirroring = mirroring
        self.screens = screens
    }

    public var enabledScreens: [ProfileScreen] { screens.filter(\.isEnabled) }
    public var identities: Set<DisplayIdentity> { Set(screens.map(\.identity)) }
}

/// One screen in a profile, matched to a connected screen by its EDID identity.
public struct ProfileScreen: Codable, Hashable, Sendable {
    public var identity: DisplayIdentity
    /// The screen's name when the profile was saved, for showing in lists.
    public var name: String
    public var isEnabled: Bool
    /// `DisplayMode.key`, e.g. "1920x1080@2x@60"; nil for screens that are off.
    public var modeKey: String?
    public var originX: Double?
    public var originY: Double?
    /// 0...1.
    public var brightness: Double?

    public init(
        identity: DisplayIdentity, name: String, isEnabled: Bool, modeKey: String? = nil,
        originX: Double? = nil, originY: Double? = nil, brightness: Double? = nil
    ) {
        self.identity = identity
        self.name = name
        self.isEnabled = isEnabled
        self.modeKey = modeKey
        self.originX = originX
        self.originY = originY
        self.brightness = brightness
    }

    public var origin: CGPoint? {
        guard let originX, let originY else { return nil }
        return CGPoint(x: originX, y: originY)
    }
}
