import DisplayKit
import ModeDockCore
import SwiftUI

struct MenuView: View {
    let screens: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    let power: PowerController
    let onOpenSettings: () -> Void

    @AppStorage(SettingsKey.sectionOrder) private var sectionOrder = ""
    @AppStorage(SettingsKey.hiddenSections) private var hiddenSections = ""
    @AppStorage(SettingsKey.collapsedSections) private var collapsedSections = ""
    @AppStorage(PanelStyle.key) private var panelStyle = PanelStyle.cards.rawValue

    private var style: PanelStyle { PanelStyle(rawValue: panelStyle) ?? .cards }

    private var layout: MenuLayout {
        MenuLayout(order: sectionOrder, hidden: hiddenSections, collapsed: collapsedSections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ForEach(layout.visible) { section in
                CollapsibleSection(
                    title: section.title,
                    isExpanded: !layout.collapsed.contains(section),
                    onToggle: { toggleCollapsed(section) }
                ) {
                    switch section {
                    case .screens:
                        if style == .rows {
                            RowsScreensSection(controller: screens, modes: modes, brightness: brightness)
                                .modifier(ModeRefresher(controller: screens, modes: modes, brightness: brightness))
                        } else {
                            ScreensSection(controller: screens, modes: modes, brightness: brightness)
                        }
                    case .power:
                        if style == .rows {
                            RowsPowerSection(power: power)
                        } else {
                            PowerSection(power: power)
                        }
                    }
                }
            }

            if layout.visible.isEmpty {
                Text("All sections are hidden. Choose what to show in Settings → Menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .environment(\.useGlass, style == .cards)
        .background(alignment: .topLeading) { keyboardShortcuts }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("ModeDock").font(.headline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")

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
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        withAnimation(.snappy(duration: 0.2)) {
            collapsedSections = MenuLayout.encode(collapsed)
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

            HStack(spacing: 8) {
                if !hidden.contains(.sleepScreens) {
                    ActionTile(title: "Sleep", systemImage: "moon.fill") {
                        controller.sleepAllDisplays()
                    }
                    .help("Sleep all screens. Move the mouse or press a key to wake them.")
                }

                if !hidden.contains(.mirror) && (modes.canMirror || modes.isMirroring) {
                    ActionTile(title: "Mirror", systemImage: "rectangle.on.rectangle", isOn: modes.isMirroring) {
                        modes.setMirroring(!modes.isMirroring)
                    }
                    .help("Show the main screen's content on every screen that's on.")
                }

                if !hidden.contains(.allOn) {
                    ActionTile(title: "All On", systemImage: "power") {
                        Task { await controller.restoreAll() }
                    }
                    .help("Turn every screen back on (⌃⌥⌘O).")
                }
            }

            if let error = controller.lastError ?? modes.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(ModeRefresher(controller: controller, modes: modes, brightness: brightness))
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
    let screen: ScreenController.Screen
    let controller: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    @AppStorage(SettingsKey.showDDCStandby) private var showDDCStandby = false
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden

    private var display: Display { screen.display }
    private var screenModes: DisplayModeController.ScreenModes? { modes.screens[screen.id] }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                header
                if display.isEnabled, !screen.isInStandby, !PanelItem.hidden(in: hiddenItems).contains(.brightness),
                    let level = brightness.screens[screen.id]
                {
                    BrightnessSlider(display: display, level: level, brightness: brightness)
                        .controlSize(.small)
                        .padding(.leading, 34)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
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
                .help(
                    screen.isInStandby
                        ? "Wake the monitor over DDC."
                        : "Put the monitor in standby over DDC. Some monitors only wake with their power button.")
            }

            CircleToggle(systemImage: "power", isOn: display.isEnabled) {
                controller.setEnabled(!display.isEnabled, screen: screen.id)
            }
            .disabled(display.isEnabled && !screen.canDisable)
            .opacity(display.isEnabled && !screen.canDisable ? 0.5 : 1)
            .help(powerHelp)
        }
    }

    @ViewBuilder private var subtitle: some View {
        if !display.isEnabled {
            Text("Off").font(.caption).foregroundStyle(.secondary)
        } else if screen.isInStandby {
            Text("Standby").font(.caption).foregroundStyle(.orange)
        } else if let screenModes {
            ModeMenu(display: screen.id, screenModes: screenModes, modes: modes)
        }
    }

    private var powerHelp: String {
        if !display.isEnabled { return "Turn the screen back on." }
        if !screen.canDisable { return "At least one screen has to stay on." }
        return "Turn the screen off. Its windows move to your other screens."
    }
}

private struct ModeMenu: View {
    let display: CGDirectDisplayID
    let screenModes: DisplayModeController.ScreenModes
    let modes: DisplayModeController

    var body: some View {
        Menu {
            ForEach(screenModes.options) { option in
                let isCurrent = option.modes.contains { $0.id == screenModes.current?.id }
                if option.modes.count == 1, let mode = option.modes.first {
                    Button(checked(isCurrent, label(option))) { modes.select(mode, for: display) }
                } else {
                    Menu(checked(isCurrent, label(option))) {
                        ForEach(option.modes) { mode in
                            Button(checked(mode.id == screenModes.current?.id, rate(mode))) {
                                modes.select(mode, for: display)
                            }
                        }
                    }
                }
            }
            if !screenModes.isMain {
                Divider()
                Button("Use as Main Screen") { modes.makeMain(display) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(summary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(modes.pending != nil)
        .help("Change resolution and refresh rate")
    }

    private var summary: String {
        guard let current = screenModes.current else { return "Resolution" }
        let size = "\(current.width) × \(current.height)"
        return current.refreshRate > 0 ? "\(size) · \(rate(current))" : size
    }

    private func label(_ option: ResolutionOption) -> String {
        var text = "\(option.width) × \(option.height)"
        // Same wording as System Settings for the 1x copy of a HiDPI size.
        let hasHiDPIVersion = screenModes.options.contains {
            $0.isHiDPI && $0.width == option.width && $0.height == option.height
        }
        if !option.isHiDPI && hasHiDPIVersion { text += " (low resolution)" }
        if option.isNative { text += " · Native" }
        return text
    }

    private func rate(_ mode: DisplayMode) -> String {
        mode.refreshRate > 0 ? "\(Int(mode.refreshRate.rounded())) Hz" : "Default"
    }

    private func checked(_ isCurrent: Bool, _ text: String) -> String {
        isCurrent ? "✓ \(text)" : text
    }
}
