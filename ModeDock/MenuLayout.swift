import SwiftUI

/// The feature areas shown in the panel, each a collapsible section that can be hidden and reordered.
enum MenuSection: String, CaseIterable, Identifiable {
    case screens, profiles, power, utilities, screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screens: "Screens"
        case .profiles: "Profiles"
        case .power: "Power"
        case .utilities: "Utilities"
        case .screenshots: "Screenshots"
        }
    }

    var systemImage: String {
        switch self {
        case .screens: "display.2"
        case .profiles: "rectangle.3.group"
        case .power: "bolt.fill"
        case .utilities: "wrench.and.screwdriver"
        case .screenshots: "camera.viewfinder"
        }
    }
}

/// Optional parts of a section, each of which can be hidden in Settings → Menu.
enum PanelItem: String, CaseIterable, Identifiable {
    case brightness, sleepScreens, mirror, allOn
    case saveProfile
    case keepAwake, battery, sleepMac, lock
    case darkMode, nightShift, trueTone, dockAutoHide, desktopIcons, hiddenFiles, emptyTrash, ejectDisks
    case screenshotArea, screenshotWindow, screenshotScreen, screenshotAllScreens

    var id: String { rawValue }

    var section: MenuSection {
        switch self {
        case .brightness, .sleepScreens, .mirror, .allOn: .screens
        case .saveProfile: .profiles
        case .keepAwake, .battery, .sleepMac, .lock: .power
        case .darkMode, .nightShift, .trueTone, .dockAutoHide, .desktopIcons, .hiddenFiles, .emptyTrash, .ejectDisks:
            .utilities
        case .screenshotArea, .screenshotWindow, .screenshotScreen, .screenshotAllScreens: .screenshots
        }
    }

    var title: String {
        switch self {
        case .brightness: "Brightness sliders"
        case .sleepScreens: "Sleep screens"
        case .mirror: "Mirror screens"
        case .allOn: "Turn all on"
        case .saveProfile: "Save current setup"
        case .keepAwake: "Keep Awake"
        case .battery: "Battery"
        case .sleepMac: "Sleep Mac"
        case .lock: "Lock screen"
        case .darkMode: "Dark Mode"
        case .nightShift: "Night Shift"
        case .trueTone: "True Tone"
        case .dockAutoHide: "Hide Dock"
        case .desktopIcons: "Desktop icons"
        case .hiddenFiles: "Hidden files"
        case .emptyTrash: "Empty Trash"
        case .ejectDisks: "Eject all disks"
        case .screenshotArea: "Capture area"
        case .screenshotWindow: "Capture window"
        case .screenshotScreen: "Capture screen"
        case .screenshotAllScreens: "Capture all screens"
        }
    }

    /// Hidden until turned on: the battery is already in the menu bar on most Macs.
    static let defaultHidden = "battery"

    static func hidden(in value: String) -> Set<PanelItem> {
        Set(CommaSeparated.decode(value))
    }

    /// For AppKit code; SwiftUI views read the same key with @AppStorage.
    static var hiddenNow: Set<PanelItem> {
        hidden(in: UserDefaults.standard.string(forKey: SettingsKey.hiddenItems) ?? defaultHidden)
    }
}

/// Section order, visibility and collapsed state, stored in user defaults as comma-separated ids.
struct MenuLayout {
    var order: [MenuSection]
    var hidden: Set<MenuSection>
    var collapsed: Set<MenuSection>

    init(order: String, hidden: String, collapsed: String) {
        let saved: [MenuSection] = CommaSeparated.decode(order)
        // Sections added in a later version go at the end.
        self.order = saved + MenuSection.allCases.filter { !saved.contains($0) }
        self.hidden = Set(CommaSeparated.decode(hidden))
        self.collapsed = Set(CommaSeparated.decode(collapsed))
    }

    var visible: [MenuSection] { order.filter { !hidden.contains($0) } }
}

/// Lists of ids as user defaults store them: "screens,power". Unknown ids are skipped.
enum CommaSeparated {
    static func encode<Value: RawRepresentable<String>>(_ values: some Sequence<Value>) -> String {
        values.map(\.rawValue).joined(separator: ",")
    }

    static func decode<Value: RawRepresentable<String>>(_ value: String) -> [Value] {
        value.split(separator: ",").compactMap { Value(rawValue: String($0)) }
    }
}

extension Set {
    /// Inserts `member` when `contains` is true, removes it otherwise.
    mutating func set(_ member: Element, contains: Bool) {
        if contains { insert(member) } else { remove(member) }
    }
}

enum SettingsKey {
    static let showDDCStandby = "showDDCStandby"
    static let showAllModes = "showAllModes"
    static let sectionOrder = "menuSectionOrder"
    static let hiddenSections = "menuHiddenSections"
    static let collapsedSections = "menuCollapsedSections"
    static let hiddenItems = "menuHiddenItems"
    /// Milliseconds between DDC brightness writes while dragging.
    static let ddcWriteInterval = "ddcWriteInterval"
    static let ddcWriteIntervalDefault = 50
    /// Minutes, 0 for "until turned off": what Keep Awake uses when it's switched on.
    static let keepAwakeDuration = "keepAwakeDuration"
    /// The last custom Keep Awake duration, in minutes.
    static let keepAwakeCustomMinutes = "keepAwakeCustomMinutes"
    /// Keep Awake also stops the screens from sleeping.
    static let keepScreensOn = "keepScreensOn"
    /// "folder" or "clipboard".
    static let screenshotDestination = "screenshotDestination"
    /// A folder path; empty for the folder macOS saves screenshots to.
    static let screenshotFolder = "screenshotFolder"
    static let screenshotFormat = "screenshotFormat"
    static let screenshotPointer = "screenshotPointer"
    static let screenshotSound = "screenshotSound"
    static let screenshotShadow = "screenshotShadow"
    /// Show a preview card after a capture.
    static let screenshotNotice = "screenshotNotice"
    /// Seconds before a screen capture.
    static let screenshotDelay = "screenshotDelay"
    static let ddcWriteIntervalSteps = [10, 20, 30, 50, 75, 100, 150, 200, 300]

    /// Every preference shown in Settings, for "Reset Settings".
    static let all = [
        showDDCStandby, showAllModes, sectionOrder, hiddenSections, collapsedSections, hiddenItems, ddcWriteInterval,
        keepAwakeDuration, keepAwakeCustomMinutes, keepScreensOn,
        screenshotDestination, screenshotFolder, screenshotFormat, screenshotPointer, screenshotSound, screenshotShadow,
        screenshotNotice, screenshotDelay,
        PanelStyle.key, AppAppearance.key,
    ]
}

/// How the menu-bar panel looks. Chosen in Settings → Menu.
enum PanelStyle: String, CaseIterable, Identifiable {
    case cards, rows, menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: "Cards"
        case .rows: "Rows"
        case .menu: "Menu"
        }
    }

    var summary: String {
        switch self {
        case .cards: "Control Center-style cards and tiles, in the system glass material on macOS 26 and later."
        case .rows: "Grouped rows with switches and pop-up menus, like Settings."
        case .menu: "A standard macOS menu, like the Wi-Fi and Sound menus."
        }
    }

    static let key = "panelStyle"

    static var current: PanelStyle {
        UserDefaults.standard.string(forKey: key).flatMap(PanelStyle.init(rawValue:)) ?? .cards
    }
}

/// ModeDock's own light or dark appearance, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static let key = "appearance"

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Applies to every ModeDock window and menu.
    @MainActor
    static func apply() {
        NSApp.appearance =
            switch current {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }
}
