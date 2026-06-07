import SwiftUI

/// The feature areas shown in the panel. New areas (Brightness, Power, ...) are added here.
enum MenuSection: String, CaseIterable, Identifiable {
    case screens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screens: "Screens"
        }
    }

    var systemImage: String {
        switch self {
        case .screens: "display.2"
        }
    }
}

/// Section order, visibility and collapsed state, stored in user defaults as comma-separated ids.
struct MenuLayout {
    var order: [MenuSection]
    var hidden: Set<MenuSection>
    var collapsed: Set<MenuSection>

    init(order: String, hidden: String, collapsed: String) {
        let saved = Self.decode(order)
        // Sections added in a later version go at the end.
        self.order = saved + MenuSection.allCases.filter { !saved.contains($0) }
        self.hidden = Set(Self.decode(hidden))
        self.collapsed = Set(Self.decode(collapsed))
    }

    var visible: [MenuSection] { order.filter { !hidden.contains($0) } }

    static func encode(_ sections: some Sequence<MenuSection>) -> String {
        sections.map(\.rawValue).joined(separator: ",")
    }

    private static func decode(_ value: String) -> [MenuSection] {
        value.split(separator: ",").compactMap { MenuSection(rawValue: String($0)) }
    }
}

enum SettingsKey {
    static let showDDCStandby = "showDDCStandby"
    static let showAllModes = "showAllModes"
    static let sectionOrder = "menuSectionOrder"
    static let hiddenSections = "menuHiddenSections"
    static let collapsedSections = "menuCollapsedSections"
    /// Milliseconds between DDC brightness writes while dragging.
    static let ddcWriteInterval = "ddcWriteInterval"
    static let ddcWriteIntervalDefault = 50
    static let ddcWriteIntervalSteps = [10, 20, 30, 50, 75, 100, 150, 200, 300]

    /// Every preference shown in Settings, for "Reset Settings".
    static let all = [
        showDDCStandby, showAllModes, sectionOrder, hiddenSections, collapsedSections, ddcWriteInterval,
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

    /// Applies to every ModeDock window and menu.
    @MainActor
    static func apply() {
        let value = UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
        NSApp.appearance =
            switch value {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }
}
