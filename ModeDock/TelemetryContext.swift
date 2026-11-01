import AppKit
import DisplayKit
import KeyboardShortcuts
import ModeDockCore
import ServiceManagement

extension TelemetryContext {
    /// The broad facts sent with the counts: nothing that identifies a person, a Mac or a screen.
    @MainActor
    static func current() -> TelemetryContext {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return TelemetryContext(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            osVersion: "\(os.majorVersion).\(os.minorVersion)",
            language: Bundle.main.preferredLocalizations.first ?? "en")
    }
}

extension TelemetrySetup {
    /// How this install is set up right now: counts, flags and choices from fixed lists only.
    @MainActor
    static func current(screens: ScreenController, profiles: ProfileController, power: PowerController)
        -> TelemetrySetup
    {
        let defaults = UserDefaults.standard
        var setup = TelemetrySetup()

        setup.profiles = profiles.profiles.count
        setup.automaticProfiles = profiles.profiles.filter(\.autoApply).count
        setup.profilesWithSystemSettings = profiles.profiles.filter { !$0.system.isEmpty }.count
        // A set shortcut is stored as text and a cleared one as false; one left at its default
        // isn't stored at all.
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("KeyboardShortcuts_") }
        let shortcuts = stored.filter { $0.value is String }.map { $0.key.dropFirst("KeyboardShortcuts_".count) }
        let defaulted = [KeyboardShortcuts.Name.togglePanel, .turnAllScreensOn]
            .filter { stored["KeyboardShortcuts_\($0.rawValue)"] == nil }
        setup.shortcuts = shortcuts.count + defaulted.count
        setup.profileShortcuts = shortcuts.filter { $0.hasPrefix("profile-") }.count
        setup.macCaptureKeys = SystemScreenshotKeys.areTakenOver
        setup.brightnessKeysAllScreens = BrightnessKeys.isEnabled

        let named = screens.screens.filter { !$0.display.identity.isPlaceholder }
        setup.externalScreens = named.filter { !$0.display.isBuiltin }.count
        setup.ddcScreens = named.filter(\.supportsDDC).count
        power.refreshBattery()
        setup.laptop = power.battery != nil
        setup.showAllResolutions = defaults.bool(forKey: SettingsKey.showAllModes)
        setup.showStandby = defaults.bool(forKey: SettingsKey.showDDCStandby)
        setup.ddcWriteInterval =
            defaults.object(forKey: SettingsKey.ddcWriteInterval) as? Int ?? SettingsKey.ddcWriteIntervalDefault

        setup.panelStyle = PanelStyle.current.rawValue
        if PanelStyle.current != .menu {
            setup.panelLayout = defaults.string(forKey: PanelLayout.key) ?? PanelLayout.tabs.rawValue
        }
        let layout = MenuLayout(
            order: defaults.string(forKey: SettingsKey.sectionOrder) ?? "",
            hidden: defaults.string(forKey: SettingsKey.hiddenSections) ?? "",
            collapsed: "")
        setup.hiddenSections = layout.hidden.map(\.rawValue).sorted()
        setup.hiddenItemsBySection = Dictionary(grouping: PanelItem.hiddenNow, by: \.section.rawValue)
            .mapValues { $0.map(\.rawValue).sorted() }

        setup.captureDestination =
            defaults.string(forKey: SettingsKey.screenshotDestination) ?? ScreenshotSettings.folder
        setup.captureFormat = defaults.string(forKey: SettingsKey.screenshotFormat) ?? ScreenshotFormat.png.rawValue
        setup.captureHDR = defaults.bool(forKey: SettingsKey.screenshotHDR)
        setup.captureOneImage = defaults.object(forKey: SettingsKey.screenshotCombineScreens) as? Bool ?? true
        setup.captureTimer = defaults.integer(forKey: SettingsKey.screenshotDelay)
        setup.capturePreview = ScreenshotSettings.showsNotice
        setup.capturePointer = defaults.bool(forKey: SettingsKey.screenshotPointer)
        setup.capturePointerEverywhere = defaults.bool(forKey: SettingsKey.screenshotPointerEverywhere)

        setup.keepAwakeMinutes = KeepAwakeSettings.minutes ?? 0
        setup.keepAwakeScreensOn = KeepAwakeSettings.keepScreensOn

        setup.languageSetting = AppLanguage.current
        setup.appearance = AppAppearance.current.rawValue
        setup.launchAtLogin = SMAppService.mainApp.status == .enabled
        setup.debugLogging = LogFile.isEnabled
        setup.optedIn = Telemetry.shared.optedInBucket
        return setup
    }
}
