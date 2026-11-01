import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

struct MenuView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    let power: PowerController
    let utilities: UtilitiesController
    let inputs: MonitorInputController
    let profiles: ProfileController
    let screenshots: ScreenshotCoordinator
    let onOpenSettings: () -> Void

    @AppStorage(SettingsKey.sectionOrder) private var sectionOrder = ""
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(SettingsKey.collapsedSections) private var collapsedSections = ""
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue
    @AppStorage(PanelLayout.key) private var panelLayout = PanelLayout.tabs.rawValue
    @AppStorage(PanelLayout.selectedTabKey) private var selectedTabID = ""

    private var style: PanelStyle { PanelStyle(rawValue: panelStyle) ?? .cards }

    private var layout: MenuLayout {
        MenuLayout(order: sectionOrder, hidden: hiddenSections, collapsed: collapsedSections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header.padding([.horizontal, .top], 14)

            if isTabbed, !layout.visible.isEmpty {
                PanelTabBar(sections: layout.visible, selected: selectedTab) { section in
                    Telemetry.shared.record(.panelTab, detail: section.rawValue)
                    selectedTabID = section.rawValue
                }
                .padding(.horizontal, 14)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isTabbed {
                        if let section = selectedTab { content(of: section) }
                    } else {
                        ForEach(layout.visible) { section in
                            CollapsibleSection(
                                title: section.title,
                                isExpanded: !layout.collapsed.contains(section),
                                onToggle: { toggleCollapsed(section) }
                            ) {
                                content(of: section)
                            }
                        }
                    }

                    if layout.visible.isEmpty {
                        Text("All sections are hidden. Show some in Settings → Menu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .bottom], 14)
                .padding(.top, 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(NoScrollEdgeEffect())
            .frame(maxHeight: maxScrollHeight)
            // Sized to the content until it reaches the cap, then it scrolls.
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
        .environment(\.useGlass, style == .cards)
        .environment(inputs)
        .background(alignment: .topLeading) { keyboardShortcuts }
    }

    private var isTabbed: Bool { (PanelLayout(rawValue: panelLayout) ?? .tabs) == .tabs }

    /// The chosen tab, or the first section when that one has been hidden.
    private var selectedTab: MenuSection? {
        MenuSection(rawValue: selectedTabID).flatMap { layout.visible.contains($0) ? $0 : nil } ?? layout.visible.first
    }

    /// The screen's height less the header, tab bar and a margin, so the panel never runs off the screen.
    private var maxScrollHeight: CGFloat {
        let screen = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame.height ?? 800
        return max(200, screen - (isTabbed ? 120 : 80))
    }

    @ViewBuilder
    private func content(of section: MenuSection) -> some View {
        switch section {
        case .screens:
            Group {
                if style == .rows {
                    RowsScreensSection(controller: screens, modes: modes, brightness: brightness)
                } else {
                    ScreensSection(controller: screens, modes: modes, brightness: brightness)
                }
            }
            .modifier(ModeRefresher(controller: screens, modes: modes, brightness: brightness))
        case .profiles:
            if style == .rows {
                RowsProfilesSection(profiles: profiles, screens: screens, modes: modes)
            } else {
                ProfilesSection(profiles: profiles, screens: screens, modes: modes)
            }
        case .power:
            if style == .rows {
                RowsPowerSection(power: power)
            } else {
                PowerSection(power: power)
            }
        case .utilities:
            if style == .rows {
                RowsUtilitiesSection(utilities: utilities)
            } else {
                UtilitiesSection(utilities: utilities)
            }
        case .screenshots:
            if style == .rows {
                RowsScreenshotsSection(screenshots: screenshots)
            } else {
                ScreenshotsSection(screenshots: screenshots)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("ModeDock").font(.headline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .tip("Settings (⌘,)")

            Menu {
                Button("Settings…", action: onOpenSettings)
                Button("Copy Diagnostics") { Diagnostics.copy(screens: screens, modes: modes) }
                Divider()
                Button("Quit ModeDock") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 14))
    }

    /// ⌘, and ⌘Q work while the panel is open, without visible buttons.
    private var keyboardShortcuts: some View {
        Group {
            Button("", action: onOpenSettings).keyboardShortcut(",")
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func toggleCollapsed(_ section: MenuSection) {
        var collapsed = layout.collapsed
        collapsed.set(section, contains: !collapsed.contains(section))
        withAnimation(.snappy(duration: 0.2)) {
            collapsedSections = CommaSeparated.encode(collapsed)
        }
    }
}

/// macOS 26 shades the area above a scroll view, which shows as a band behind the header.
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// The icon bar of the Tabs layout, one button per visible section.
private struct PanelTabBar: View {
    let sections: [MenuSection]
    let selected: MenuSection?
    let onSelect: (MenuSection) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(sections) { section in
                let isSelected = section == selected
                Button {
                    onSelect(section)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(height: 18)
                        Text(section.tabTitle)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 4)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        isSelected ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tip(verbatim: section.tabTitle)
            }
        }
    }
}

private struct ScreensSection: View {
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(controller.screens) { screen in
                ScreenCard(screen: screen, controller: controller, modes: modes, brightness: brightness)
            }

            HStack(spacing: 6) {
                if !hidden.contains(.sleepScreens) {
                    ActionTile(title: String(localized: "Sleep"), systemImage: "moon.fill") {
                        controller.sleepAllDisplays()
                    }
                    .tip("Sleep all screens. Move the mouse to wake them.")
                }

                if !hidden.contains(.mirror) && (modes.canMirror || modes.isMirroring) {
                    ActionTile(
                        title: String(localized: "Mirror"), systemImage: "rectangle.on.rectangle",
                        isOn: modes.isMirroring
                    ) {
                        modes.setMirroring(!modes.isMirroring)
                    }
                    .tip("Show the main screen on every screen.")
                }

                if !hidden.contains(.allOn) {
                    ActionTile(title: String(localized: "All On"), systemImage: "power") {
                        Telemetry.shared.record(.screensAllOn)
                        Task { await controller.restoreAll() }
                    }
                    .tip(
                        KeyboardShortcuts.Name.turnAllScreensOn.shortcutText.map {
                            "Turn every screen back on (\($0))."
                        } ?? "Turn every screen back on.")
                }
            }

            ErrorLabel(controller.lastError ?? modes.lastError)
        }
    }
}

/// Reloads display modes and brightness whenever the screens or the "show all" setting change.
struct ModeRefresher: ViewModifier {
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.showAllModes) private var showAllModes = false

    func body(content: Content) -> some View {
        content
            .onAppear(perform: refresh)
            .onChange(of: controller.screens) { refresh() }
            .onChange(of: showAllModes) { refresh() }
            // Automatic brightness and the brightness keys change the level behind our back.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    brightness.syncSystemBrightness()
                }
            }
    }

    private func refresh() {
        let displays = controller.screens.map(\.display)
        modes.refresh(displays: displays, showAllModes: showAllModes)
        Task { await brightness.refresh(displays: displays) }
    }
}

private struct ScreenCard: View {
    @Environment(MonitorInputController.self) private var inputs
    let screen: ScreenController.Screen
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    @State private var showingModes = false

    private var display: Display { screen.display }
    private var screenModes: DisplayModeController.ScreenModes? { modes.screens[screen.id] }

    var body: some View {
        VStack(spacing: 6) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if display.isEnabled, !screen.isInStandby,
                        !PanelItem.hidden(in: hiddenItems).contains(.brightness),
                        let level = brightness.screens[screen.id]
                    {
                        BrightnessSlider(display: display, level: level, brightness: brightness)
                            .controlSize(.small)
                            .padding(.leading, 34)
                    }
                }
            }
            // Below the card rather than inside it: controls inside interactive glass have
            // crashed SwiftUI on macOS 26.
            if let change = modes.pending, change.display == screen.id {
                PendingResolutionStrip(change: change, modes: modes)
            } else if showingModes, display.isEnabled, let screenModes {
                ResolutionList(display: screen.id, screenModes: screenModes, modes: modes) {
                    showingModes = false
                }
                if let available = inputs.screens[screen.id] {
                    InputChips(display: screen.id, inputs: available)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: display.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(display.isEnabled ? .primary : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if screenModes?.isMain == true && display.isEnabled {
                        Text("Main")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.1), in: Capsule())
                    }
                }
                subtitle
            }

            Spacer(minLength: 4)

            if showDDCStandby && screen.supportsDDC && display.isEnabled {
                CircleToggle(systemImage: "moon.zzz", isOn: screen.isInStandby, size: 24) {
                    Task { await controller.setStandby(!screen.isInStandby, screen: screen.id) }
                }
                .tip(
                    screen.isInStandby
                        ? "Wake the monitor over DDC."
                        : "Put the monitor in standby over DDC. Some monitors only wake with their power button.")
            }

            CircleToggle(systemImage: "power", isOn: display.isEnabled) {
                Telemetry.shared.record(.screenToggled)
                controller.setEnabled(!display.isEnabled, screen: screen.id)
            }
            .disabled(display.isEnabled && !screen.canDisable)
            .opacity(display.isEnabled && !screen.canDisable ? 0.5 : 1)
            .tip(verbatim: powerHelp)
        }
    }

    @ViewBuilder private var subtitle: some View {
        if !display.isEnabled {
            Text("Off").font(.caption).foregroundStyle(.secondary)
        } else if screen.isInStandby {
            Text("Standby").font(.caption).foregroundStyle(.orange)
        } else if let screenModes {
            Button {
                showingModes.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: screenModes.current?.summary ?? "Resolution")
                    Image(systemName: showingModes ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(modes.pending != nil)
            .tip("Change resolution and refresh rate")
        }
    }

    private var powerHelp: String {
        if !display.isEnabled { return String(localized: "Turn the screen back on.") }
        if !screen.canDisable { return String(localized: "At least one screen has to stay on.") }
        return String(localized: "Turn the screen off. Its windows move to the other screens.")
    }
}
