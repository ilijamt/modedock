import DisplayKit
import Foundation
import KeyboardShortcuts
import ModeDockCore

enum ConfigGroup: String, CaseIterable, Identifiable, Codable, CodingKeyRepresentable {
    case general, menu, displays, capture, shortcuts, profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .menu: String(localized: "Menu")
        case .displays: String(localized: "Displays")
        case .capture: String(localized: "Capture")
        case .shortcuts: String(localized: "Shortcuts")
        case .profiles: String(localized: "Profiles")
        }
    }

    var summary: String {
        switch self {
        case .general: String(localized: "Appearance, language, Keep Awake and debug logging")
        case .menu: String(localized: "Panel style, layout, sections and items")
        case .displays: String(localized: "Resolutions, monitor brightness and brightness keys")
        case .capture: String(localized: "Where screenshots go and how they're taken")
        case .shortcuts: String(localized: "All shortcuts except profile shortcuts")
        case .profiles: String(localized: "Profiles and their shortcuts")
        }
    }

    var settingKeys: [String] {
        switch self {
        case .general:
            [
                AppAppearance.key, AppLanguage.key, SettingsKey.keepAwakeDuration, SettingsKey.keepAwakeCustomMinutes,
                SettingsKey.keepScreensOn, LogFile.enabledKey,
            ]
        case .menu:
            [
                PanelStyle.key, PanelLayout.key, PanelLayout.selectedTabKey, SettingsKey.sectionOrder,
                SettingsKey.hiddenSections, SettingsKey.collapsedSections, SettingsKey.hiddenItems,
            ]
        case .displays:
            [
                SettingsKey.showDDCStandby, SettingsKey.showAllModes, SettingsKey.ddcWriteInterval,
                SettingsKey.brightnessKeysAllScreens,
            ]
        case .capture:
            [
                SettingsKey.screenshotDestination, SettingsKey.screenshotFolder, SettingsKey.screenshotFormat,
                SettingsKey.screenshotHDR, SettingsKey.screenshotPointer, SettingsKey.screenshotPointerEverywhere,
                SettingsKey.screenshotSound, SettingsKey.screenshotShadow, SettingsKey.screenshotNotice,
                SettingsKey.screenshotNoticePicture, SettingsKey.screenshotHidesPanel, SettingsKey.screenshotDelay,
                SettingsKey.screenshotCombineScreens,
            ]
        case .shortcuts: [SettingsKey.profileCycleScope]
        case .profiles: []
        }
    }

    /// Whether a shortcut belongs to this group: profile shortcuts go with the profiles.
    func owns(shortcut name: String) -> Bool {
        switch self {
        case .shortcuts: !name.hasPrefix(Self.profileShortcutPrefix)
        case .profiles: name.hasPrefix(Self.profileShortcutPrefix)
        default: false
        }
    }

    var hasShortcuts: Bool { self == .shortcuts || self == .profiles }

    private static let profileShortcutPrefix = "profile-"
}

enum SettingValue: Codable, Equatable {
    case bool(Bool), int(Int), double(Double), string(String)

    init?(_ value: Any) {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
        } else if let int = value as? Int {
            self = .int(int)
        } else if let double = value as? Double {
            self = .double(double)
        } else if let string = value as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    var value: Any {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// The exported file. Groups that weren't exported are missing, and importing leaves them alone.
struct ConfigFile: Codable {
    struct Group: Codable {
        var settings: [String: SettingValue]?
        /// A missing shortcut is unset; null is one the user cleared.
        var shortcuts: [String: KeyboardShortcuts.Shortcut?]?
        var profiles: [DisplayProfile]?
    }

    static let formatName = "ModeDock configuration"

    var format = Self.formatName
    var version = 1
    var appVersion: String
    var exportedAt: Date
    var groups: [ConfigGroup: Group]

    enum ImportError: LocalizedError {
        case notAConfiguration

        var errorDescription: String? { String(localized: "This file isn't a ModeDock configuration.") }
    }
}

@MainActor
enum Configuration {
    private static let shortcutPrefix = "KeyboardShortcuts_"

    static func export(_ groups: Set<ConfigGroup>, profiles: ProfileController) throws -> Data {
        Telemetry.shared.record(.configExport)
        for group in groups { Telemetry.shared.record(.configExport, detail: group.rawValue) }
        let defaults = UserDefaults.standard
        let stored = defaults.dictionaryRepresentation()
        var file = ConfigFile(appVersion: Bundle.main.versionString, exportedAt: .now, groups: [:])
        for group in ConfigGroup.allCases where groups.contains(group) {
            var data = ConfigFile.Group()
            if !group.settingKeys.isEmpty {
                data.settings = group.settingKeys.reduce(into: [:]) { settings, key in
                    if let value = defaults.object(forKey: key).flatMap(SettingValue.init) { settings[key] = value }
                }
            }
            if group.hasShortcuts {
                data.shortcuts = [:]
                for (key, value) in stored where key.hasPrefix(shortcutPrefix) {
                    let name = String(key.dropFirst(shortcutPrefix.count))
                    guard group.owns(shortcut: name) else { continue }
                    // A cleared shortcut is stored as false, and kept in the file as null.
                    data.shortcuts?.updateValue((value as? String).flatMap(shortcut(from:)), forKey: name)
                }
            }
            if group == .profiles { data.profiles = profiles.profiles }
            file.groups[group] = data
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func read(_ data: Data) throws -> ConfigFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(ConfigFile.self, from: data), file.format == ConfigFile.formatName
        else { throw ConfigFile.ImportError.notAConfiguration }
        return file
    }

    /// Replaces the chosen groups with the file's; settings and shortcuts a group doesn't list
    /// go back to their defaults. Other groups stay as they are.
    static func apply(_ file: ConfigFile, groups: Set<ConfigGroup>, profiles: ProfileController) {
        Telemetry.shared.record(.configImport)
        for group in groups { Telemetry.shared.record(.configImport, detail: group.rawValue) }
        let defaults = UserDefaults.standard
        for group in ConfigGroup.allCases where groups.contains(group) {
            guard let data = file.groups[group] else { continue }
            for key in group.settingKeys {
                if let value = data.settings?[key] {
                    defaults.set(value.value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            if group == .capture, let folder = defaults.string(forKey: SettingsKey.screenshotFolder),
                !folder.isEmpty, !FileManager.default.fileExists(atPath: folder)
            {
                // A folder from another Mac; fall back to where macOS saves screenshots.
                defaults.removeObject(forKey: SettingsKey.screenshotFolder)
            }
            if group == .profiles, let imported = data.profiles {
                for profile in profiles.profiles where !imported.contains(where: { $0.id == profile.id }) {
                    profiles.deleteWithShortcut(profile.id)
                }
                profiles.replaceAll(with: imported)
            }
            if group.hasShortcuts { applyShortcuts(data.shortcuts ?? [:], for: group) }
        }
        AppAppearance.apply()
        AppLanguage.apply()
    }

    static func applyShortcuts(_ shortcuts: [String: KeyboardShortcuts.Shortcut?], for group: ConfigGroup) {
        let current = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(shortcutPrefix) }
            .map { String($0.dropFirst(shortcutPrefix.count)) }
            .filter(group.owns(shortcut:))
        for name in current where shortcuts[name] == nil {
            KeyboardShortcuts.reset(shortcutName(name))
        }
        for (name, shortcut) in shortcuts {
            KeyboardShortcuts.setShortcut(shortcut, for: shortcutName(name))
        }
    }

    /// The shared names for shortcuts with a default, so resetting brings that default back; a
    /// name made from text alone has none.
    private static func shortcutName(_ name: String) -> KeyboardShortcuts.Name {
        [KeyboardShortcuts.Name.togglePanel, .turnAllScreensOn].first { $0.rawValue == name }
            ?? KeyboardShortcuts.Name(name)
    }

    private static func shortcut(from json: String) -> KeyboardShortcuts.Shortcut? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: $0) }
    }
}
