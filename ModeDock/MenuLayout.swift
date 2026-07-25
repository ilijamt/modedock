import DisplayKit
import SwiftUI

/// The feature areas shown in the panel, each a collapsible section that can be hidden and reordered.
enum MenuSection: String, CaseIterable, Identifiable {
    case screens, profiles, power, utilities, screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screens: String(localized: "Screens")
        case .profiles: String(localized: "Profiles")
        case .power: String(localized: "Power")
        case .utilities: String(localized: "Utilities")
        case .screenshots: String(localized: "Capture")
        }
    }

    /// For the tab bar, where five titles share the panel's width.
    var tabTitle: String {
        switch self {
        // Its own key, so languages with a long word for Utilities can use a shorter one here.
        case .utilities: String(localized: "tab.utilities", defaultValue: "Utilities")
        default: title
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
    case screenshotArea, screenshotWindow, screenshotScreen, screenshotAllScreens, screenshotOptions

    var id: String { rawValue }

    var section: MenuSection {
        switch self {
        case .brightness, .sleepScreens, .mirror, .allOn: .screens
        case .saveProfile: .profiles
        case .keepAwake, .battery, .sleepMac, .lock: .power
        case .darkMode, .nightShift, .trueTone, .dockAutoHide, .desktopIcons, .hiddenFiles, .emptyTrash, .ejectDisks:
            .utilities
        case .screenshotArea, .screenshotWindow, .screenshotScreen, .screenshotAllScreens, .screenshotOptions:
            .screenshots
        }
    }

    var title: String {
        switch self {
        case .brightness: String(localized: "Brightness sliders")
        case .sleepScreens: String(localized: "Sleep screens")
        case .mirror: String(localized: "Mirror screens")
        case .allOn: String(localized: "Turn all on")
        case .saveProfile: String(localized: "Save current setup")
        case .keepAwake: String(localized: "Keep Awake")
        case .battery: String(localized: "Battery")
        case .sleepMac: String(localized: "Sleep Mac")
        case .lock: String(localized: "Lock screen")
        case .darkMode: String(localized: "Dark Mode")
        case .nightShift: String(localized: "Night Shift")
        case .trueTone: String(localized: "True Tone")
        case .dockAutoHide: String(localized: "Hide Dock")
        case .desktopIcons: String(localized: "Desktop icons")
        case .hiddenFiles: String(localized: "Hidden files")
        case .emptyTrash: String(localized: "Empty Trash")
        case .ejectDisks: String(localized: "Eject all disks")
        case .screenshotArea: String(localized: "Capture area")
        case .screenshotWindow: String(localized: "Capture window")
        case .screenshotScreen: String(localized: "Capture screen")
        case .screenshotAllScreens: String(localized: "Capture all screens")
        case .screenshotOptions: String(localized: "Save to and timer")
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
    /// Capture HDR content with its extended range.
    static let screenshotHDR = "screenshotHDR"
    static let screenshotPointer = "screenshotPointer"
    /// Experimental: also draw the pointer into Area and Window captures.
    static let screenshotPointerEverywhere = "screenshotPointerEverywhere"
    static let screenshotSound = "screenshotSound"
    static let screenshotShadow = "screenshotShadow"
    /// Show a preview card after a capture.
    static let screenshotNotice = "screenshotNotice"
    /// Close the panel before capturing, so it isn't in the screenshot.
    static let screenshotHidesPanel = "screenshotHidesPanel"
    /// The preview card shows the picture, not just an icon.
    static let screenshotNoticePicture = "screenshotNoticePicture"
    /// All Screens saves one image of every screen instead of a file each.
    static let screenshotCombineScreens = "screenshotCombineScreens"
    /// Seconds before a screen capture.
    static let screenshotDelay = "screenshotDelay"
    /// "connected" or "all": which profiles the Next Profile shortcut cycles through.
    static let profileCycleScope = "profileCycleScope"
    /// The keyboard's brightness keys change every screen.
    static let brightnessKeysAllScreens = "brightnessKeysAllScreens"
    static let ddcWriteIntervalSteps = [10, 20, 30, 50, 75, 100, 150, 200, 300]

    /// Every preference shown in Settings, for "Reset Settings": the same lists as export and import.
    static var all: [String] { ConfigGroup.allCases.flatMap(\.settingKeys) }
}

/// How the menu-bar panel looks. Chosen in Settings → Menu.
enum PanelStyle: String, CaseIterable, Identifiable {
    case cards, rows, menu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: String(localized: "Cards")
        case .rows: String(localized: "Rows")
        case .menu: String(localized: "Menu")
        }
    }

    var summary: String {
        switch self {
        case .cards: String(localized: "Cards and tiles, like Control Center.")
        case .rows: String(localized: "Grouped rows with switches, like Settings.")
        case .menu: String(localized: "A standard menu, like Wi-Fi and Sound.")
        }
    }

    static let key = "panelStyle"

    static var current: PanelStyle {
        UserDefaults.standard.string(forKey: key).flatMap(PanelStyle.init(rawValue:)) ?? .cards
    }
}

/// Whether the panel lists every section or shows one at a time under a tab bar.
enum PanelLayout: String, CaseIterable, Identifiable {
    case list, tabs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: String(localized: "List")
        case .tabs: String(localized: "Tabs")
        }
    }

    var summary: String {
        switch self {
        case .list: String(localized: "All sections in one scrolling list.")
        case .tabs: String(localized: "One section at a time, picked from tabs.")
        }
    }

    static let key = "panelLayout"
    static let selectedTabKey = "panelSelectedTab"
}

/// ModeDock's own light or dark appearance, independent of the system setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
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
