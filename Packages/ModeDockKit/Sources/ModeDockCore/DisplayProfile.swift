import CoreGraphics
import DisplayKit
import Foundation

public struct DisplayProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var autoApply: Bool
    public var mirroring: Bool
    public var screens: [ProfileScreen]
    public var system: ProfileSystemSettings

    public init(
        id: UUID = UUID(), name: String, autoApply: Bool = false, mirroring: Bool = false,
        screens: [ProfileScreen], system: ProfileSystemSettings = ProfileSystemSettings()
    ) {
        self.id = id
        self.name = name
        self.autoApply = autoApply
        self.mirroring = mirroring
        self.screens = screens
        self.system = system
    }

    // Profiles saved before system settings existed decode with none set.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        autoApply = try container.decode(Bool.self, forKey: .autoApply)
        mirroring = try container.decode(Bool.self, forKey: .mirroring)
        screens = try container.decode([ProfileScreen].self, forKey: .screens)
        system = try container.decodeIfPresent(ProfileSystemSettings.self, forKey: .system) ?? ProfileSystemSettings()
    }

    public var enabledScreens: [ProfileScreen] { screens.filter(\.isEnabled) }
    public var identities: Set<DisplayIdentity> { Set(screens.map(\.identity)) }
}

public struct ProfileSystemSettings: Codable, Hashable, Sendable {
    public var darkMode: Bool?
    public var nightShift: Bool?
    public var trueTone: Bool?
    public var dockAutoHide: Bool?

    public init(darkMode: Bool? = nil, nightShift: Bool? = nil, trueTone: Bool? = nil, dockAutoHide: Bool? = nil) {
        self.darkMode = darkMode
        self.nightShift = nightShift
        self.trueTone = trueTone
        self.dockAutoHide = dockAutoHide
    }

    public enum Setting: CaseIterable, Sendable {
        case darkMode, nightShift, trueTone, dockAutoHide

        var keyPath: WritableKeyPath<ProfileSystemSettings, Bool?> {
            switch self {
            case .darkMode: \.darkMode
            case .nightShift: \.nightShift
            case .trueTone: \.trueTone
            case .dockAutoHide: \.dockAutoHide
            }
        }

        public var stateKeyPath: KeyPath<UtilityState, Bool?> { state }

        var state: KeyPath<UtilityState, Bool?> {
            switch self {
            case .darkMode: \.darkMode
            case .nightShift: \.nightShift
            case .trueTone: \.trueTone
            case .dockAutoHide: \.dockAutoHide
            }
        }
    }

    public subscript(setting: Setting) -> Bool? {
        get { self[keyPath: setting.keyPath] }
        set { self[keyPath: setting.keyPath] = newValue }
    }

    public var isEmpty: Bool { Setting.allCases.allSatisfy { self[$0] == nil } }

    /// Settings the Mac doesn't have are skipped.
    func matches(_ state: UtilityState) -> Bool {
        Setting.allCases.allSatisfy { setting in
            guard let wanted = self[setting], let current = state[keyPath: setting.state] else { return true }
            return wanted == current
        }
    }
}

public struct ProfileScreen: Codable, Hashable, Sendable {
    public var identity: DisplayIdentity
    public var name: String
    public var isEnabled: Bool
    /// `DisplayMode.key`, e.g. "1920x1080@2x@60"; nil for screens that are off.
    public var modeKey: String?
    public var originX: Double?
    public var originY: Double?
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
