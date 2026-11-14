import AppKit
import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import SwiftUI

// None of these has a default: they're only active once the user records one.
extension KeyboardShortcuts.Name {
    static let brightnessUp = Self("brightnessUp")
    static let brightnessDown = Self("brightnessDown")
    static let sleepScreens = Self("sleepScreens")
    static let toggleMirror = Self("toggleMirror")
    static let nextProfile = Self("nextProfile")
    static let toggleKeepAwake = Self("toggleKeepAwake")
    static let toggleDarkMode = Self("toggleDarkMode")
    static let toggleNightShift = Self("toggleNightShift")
    static let toggleTrueTone = Self("toggleTrueTone")
    static let toggleDesktopIcons = Self("toggleDesktopIcons")
    static let ejectAllDisks = Self("ejectAllDisks")
}

extension AppLog {
    static let shortcuts = AppLog("shortcuts")
}

@MainActor
final class ShortcutActions {
    /// macOS moves brightness in sixteenths with the brightness keys.
    static let brightnessStep = 1.0 / 16

    private let screens: ScreenController
    private let modes: DisplayModeController
    private let brightness: BrightnessController
    private let power: PowerController
    private let utilities: UtilitiesController
    private let profiles: ProfileController
    private let hud = ShortcutHUD()
    private lazy var switcher = ProfileSwitcher(profiles: profiles, screens: screens, modes: modes, hud: hud)

    init(
        screens: ScreenController, modes: DisplayModeController, brightness: BrightnessController,
        power: PowerController, utilities: UtilitiesController, profiles: ProfileController
    ) {
        self.screens = screens
        self.modes = modes
        self.brightness = brightness
        self.power = power
        self.utilities = utilities
        self.profiles = profiles
    }

    func start() {
        onKeyDown(.brightnessUp) { [weak self] in self?.changeBrightness(by: Self.brightnessStep)
        }
        onKeyDown(.brightnessDown) { [weak self] in
            self?.changeBrightness(by: -Self.brightnessStep)
        }
        onKeyUp(.sleepScreens) { [weak self] in self?.screens.sleepAllDisplays() }
        onKeyUp(.toggleMirror) { [weak self] in self?.toggleMirror() }
        onKeyUp(.nextProfile) { [weak self] in self?.switcher.next() }
        onKeyUp(.toggleKeepAwake) { [weak self] in self?.toggleKeepAwake() }
        onKeyUp(.toggleDarkMode) { [weak self] in
            self?.toggle("Dark Mode", "circle.lefthalf.filled", { $0.darkMode }) { $0.setDarkMode($1) }
        }
        onKeyUp(.toggleNightShift) { [weak self] in
            self?.toggle("Night Shift", "sunset.fill", { $0.nightShift }) { $0.setNightShift($1) }
        }
        onKeyUp(.toggleTrueTone) { [weak self] in
            self?.toggle("True Tone", "sun.max.fill", { $0.trueTone }) { $0.setTrueTone($1) }
        }
        onKeyUp(.toggleDesktopIcons) { [weak self] in
            self?.toggle(String(localized: "Desktop Icons"), "square.grid.2x2", { $0.desktopIcons }) {
                $0.setDesktopIcons($1)
            }
        }
        onKeyUp(.ejectAllDisks) { [weak self] in self?.ejectAll() }
    }

    /// Global shortcuts, counted (anonymously, when allowed) as source.shortcut, by name.
    private func onKeyUp(_ name: KeyboardShortcuts.Name, _ action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name) {
            Telemetry.shared.recordShortcut(name.rawValue)
            action()
        }
    }

    private func onKeyDown(_ name: KeyboardShortcuts.Name, _ action: @escaping @MainActor () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name) {
            Telemetry.shared.recordShortcut(name.rawValue)
            action()
        }
    }

    private var displays: [Display] { screens.screens.map(\.display) }

    private func refreshModes() {
        modes.refresh(
            displays: displays, showAllModes: UserDefaults.standard.bool(forKey: SettingsKey.showAllModes))
    }

    /// Every screen that's on moves by the same step; the bubble shows the level of the screen
    /// under the pointer.
    func changeBrightness(by step: Double) {
        Task {
            if brightness.screens.isEmpty { await brightness.refresh(displays: displays) }
            brightness.syncSystemBrightness()
            for (id, screen) in brightness.screens {
                brightness.set(screen.value + step, for: id)
            }
            let id = NSScreen.underMouse?.displayID
            guard let level = id.flatMap({ brightness.screens[$0] }) ?? brightness.screens.values.first else {
                hud.show(String(localized: "No screen supports brightness"), systemImage: "sun.max")
                return
            }
            hud.show(String(localized: "Brightness"), systemImage: "sun.max.fill", level: level.value)
        }
    }

    private func toggleMirror() {
        refreshModes()
        guard modes.canMirror || modes.isMirroring else {
            hud.show(String(localized: "Mirroring needs two screens"), systemImage: "rectangle.on.rectangle")
            return
        }
        modes.setMirroring(!modes.isMirroring)
        showResult(
            modes.lastError,
            success: modes.isMirroring ? String(localized: "Mirroring On") : String(localized: "Mirroring Off"),
            systemImage: "rectangle.on.rectangle")
    }

    private func toggleKeepAwake() {
        KeepAwakeSettings.toggle(power)
        showResult(
            power.lastError,
            success: power.isKeepingAwake ? String(localized: "Keep Awake On") : String(localized: "Keep Awake Off"),
            systemImage: "cup.and.saucer.fill")
    }

    private func toggle(
        _ title: String, _ systemImage: String, _ state: (UtilityState) -> Bool?,
        set: (UtilitiesController, Bool) -> Void
    ) {
        utilities.refresh()
        guard let isOn = state(utilities.state) else {
            hud.show(String(localized: "\(title) isn't available on this Mac"), systemImage: systemImage)
            return
        }
        set(utilities, !isOn)
        let nowOn = state(utilities.state) ?? !isOn
        showResult(
            utilities.lastError, success: nowOn ? String(localized: "\(title) On") : String(localized: "\(title) Off"),
            systemImage: systemImage)
    }

    private func ejectAll() {
        utilities.refresh()
        let count = utilities.state.ejectableVolumes
        guard count > 0 else {
            hud.show(String(localized: "No disks to eject"), systemImage: "eject.fill")
            return
        }
        Task {
            await utilities.ejectAll()
            showResult(
                utilities.lastError, success: String(localized: "\(count) disks ejected"),
                systemImage: "eject.fill")
        }
    }

    private func showResult(_ error: String?, success: String, systemImage: String) {
        AppLog.shortcuts.info(error.map { "\(success): failed: \($0)" } ?? success)
        if let error {
            hud.show(error, systemImage: "exclamationmark.triangle.fill")
        } else {
            hud.show(success, systemImage: systemImage)
        }
    }
}

@MainActor
final class ShortcutHUD {
    private let panel: FloatingPanel = {
        let panel = FloatingPanel(level: .popUpMenu)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        return panel
    }()
    private var hideTask: Task<Void, Never>?

    func show(_ title: String, systemImage: String, level: Double? = nil) {
        // A plain hosting view sized once: letting it resize the panel on its own looped in layout.
        let content = NSHostingView(
            rootView: HUDView(title: title, systemImage: systemImage, level: level)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        content.sizingOptions = []
        let size = content.fittingSize
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.setContentSize(size)
        if let screen = NSScreen.underMouse ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 100))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [panel] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup {
                $0.duration = 0.3; panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private struct HUDView: View {
    let title: String
    let systemImage: String
    let level: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let level {
                    ProgressView(value: level).progressViewStyle(.linear)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 240, alignment: .leading)
    }
}
