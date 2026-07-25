import ModeDockCore
import SwiftUI

/// Keep Awake preferences shared by every panel style.
@MainActor
enum KeepAwakeSettings {
    /// What Keep Awake uses when it's switched on: the last duration picked, nil for "until
    /// turned off". Stored as minutes, 0 for "until turned off".
    static var minutes: Int? {
        get { positiveInt(forKey: SettingsKey.keepAwakeDuration) }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKey.keepAwakeDuration) }
    }

    /// Prefills the custom duration field.
    static var lastCustomMinutes: Int? {
        get { positiveInt(forKey: SettingsKey.keepAwakeCustomMinutes) }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: SettingsKey.keepAwakeCustomMinutes) }
    }

    static var keepScreensOn: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.keepScreensOn) as? Bool ?? true
    }

    static func start(minutes: Int?, power: PowerController) {
        Self.minutes = minutes
        power.startKeepAwake(minutes: minutes, keepScreensOn: keepScreensOn)
    }

    static func setKeepScreensOn(_ on: Bool, power: PowerController) {
        UserDefaults.standard.set(on, forKey: SettingsKey.keepScreensOn)
        power.setKeepScreensOn(on)
    }

    static func toggle(_ power: PowerController) {
        if power.isKeepingAwake { power.stopKeepAwake() } else { start(minutes: minutes, power: power) }
    }

    /// Whether `minutes` is one of the menu presets; anything else shows as "Custom".
    static func isPreset(_ minutes: Int?) -> Bool {
        PowerController.presets.contains { $0 == minutes }
    }

    /// "Custom (1 h 30 min)" for a duration that isn't a preset; nil for a preset. 0 is
    /// "until turned off", like nil.
    static func customLabel(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0, !isPreset(minutes) else { return nil }
        return String(localized: "Custom (\(PowerController.title(minutes: minutes)))")
    }

    private static func positiveInt(forKey key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }
}

extension BatteryStatus {
    var summary: String {
        var parts = ["\(percent)%"]
        switch state {
        case .onBattery: if let time { parts.append(String(localized: "\(time) left")) }
        case .charging:
            parts.append(time.map { String(localized: "\($0) until full") } ?? String(localized: "Charging"))
        case .charged: parts.append(String(localized: "Charged"))
        case .notCharging: parts.append(String(localized: "Not charging"))
        }
        return parts.joined(separator: " · ")
    }

    var systemImage: String {
        if state == .charging { return "battery.100percent.bolt" }
        return switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var time: String? {
        minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) }
    }
}

/// Reads the battery when the section appears and every 30 seconds while it's visible.
private struct BatteryRefresher: ViewModifier {
    let power: PowerController

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                power.refreshBattery()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// The Power section in the Cards style.
struct PowerSection: View {
    let power: PowerController
    @State private var editingCustom = false
    @AppStorage(SettingsKey.keepScreensOn) private var keepScreensOn = true
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    var body: some View {
        VStack(spacing: 8) {
            if !hidden.contains(.keepAwake) {
                keepAwakeCard
            }

            if !hidden.contains(.battery), let battery = power.battery {
                batteryCard(battery)
            }

            if !hidden.contains(.sleepMac) || !hidden.contains(.lock) {
                HStack(spacing: 6) {
                    if !hidden.contains(.sleepMac) {
                        ActionTile(title: String(localized: "Sleep Mac"), systemImage: "powersleep") { power.sleep() }
                            .tip("Put the Mac to sleep now.")
                    }
                    if !hidden.contains(.lock) {
                        ActionTile(title: String(localized: "Lock"), systemImage: "lock.fill") { power.lockScreen() }
                            .tip("Lock the screen (⌃⌘Q).")
                    }
                }
            }

            ErrorLabel(power.lastError)
        }
        .modifier(BatteryRefresher(power: power))
    }

    private var keepAwakeCard: some View {
        VStack(spacing: 6) {
            Card { keepAwakeHeader }
            // Outside the card: text fields and segmented controls inside interactive glass crash
            // SwiftUI on macOS 26 (endless recursion while resolving the glass material).
            if editingCustom {
                CustomKeepAwakeEditor(power: power) {
                    editingCustom = false
                }
                .controlSize(.small)
                .padding(10)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var keepAwakeHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 15))
                .foregroundStyle(power.isKeepingAwake ? .primary : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep Awake").font(.system(size: 13, weight: .medium)).lineLimit(1).fixedSize()
                KeepAwakeMenu(power: power) { editingCustom = true }
            }
            Spacer(minLength: 4)
            CircleToggle(systemImage: "display", isOn: keepScreensOn, size: 24) {
                KeepAwakeSettings.setKeepScreensOn(!keepScreensOn, power: power)
            }
            .tip(
                keepScreensOn
                    ? "Screens stay on during Keep Awake. Click to let them sleep."
                    : "Screens can sleep during Keep Awake. Click to keep them on.")
            CircleToggle(systemImage: "power", isOn: power.isKeepingAwake) {
                KeepAwakeSettings.toggle(power)
            }
            .tip(power.isKeepingAwake ? "Let the Mac sleep again." : "Stop the Mac from going to sleep.")
        }
    }

    private func batteryCard(_ battery: BatteryStatus) -> some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: battery.systemImage)
                    .font(.system(size: 15))
                    .frame(width: 24)
                Text("Battery").font(.system(size: 13, weight: .medium))
                Spacer(minLength: 4)
                Text(verbatim: battery.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows whether Keep Awake is on and for how long, and picks the duration.
private struct KeepAwakeMenu: View {
    let power: PowerController
    let onCustom: () -> Void

    var body: some View {
        Menu {
            ForEach(PowerController.presets, id: \.self) { minutes in
                let title = PowerController.title(minutes: minutes)
                Button(power.isKeepingAwake && power.keepAwake?.minutes == minutes ? "✓ \(title)" : title) {
                    KeepAwakeSettings.start(minutes: minutes, power: power)
                }
            }
            Button(customTitle, action: onCustom)
            if power.isKeepingAwake {
                Divider()
                Button("Turn Off") { power.stopKeepAwake() }
            }
        } label: {
            HStack(spacing: 3) {
                status
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip("Choose how long to keep the Mac awake")
    }

    private var customTitle: String {
        KeepAwakeSettings.customLabel(power.keepAwake?.minutes).map { "✓ \($0)…" } ?? "Custom…"
    }

    @ViewBuilder private var status: some View {
        if let keepAwake = power.keepAwake {
            if let endsAt = keepAwake.endsAt {
                HStack(spacing: 0) {
                    Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true).monospacedDigit()
                    Text(verbatim: " left")
                }
            } else {
                Text("Until turned off")
            }
        } else {
            Text("Off")
        }
    }
}

/// The Power section in the Rows style.
struct RowsPowerSection: View {
    let power: PowerController
    @State private var editingCustom = false
    @AppStorage(SettingsKey.keepScreensOn) private var keepScreensOn = true
    @AppStorage(SettingsKey.hiddenItems) private var hiddenItems = PanelItem.defaultHidden
    private var hidden: Set<PanelItem> { PanelItem.hidden(in: hiddenItems) }

    private var battery: BatteryStatus? { hidden.contains(.battery) ? nil : power.battery }

    var body: some View {
        VStack(spacing: 10) {
            if !hidden.contains(.keepAwake) || battery != nil {
                RowGroup {
                    if !hidden.contains(.keepAwake) {
                        keepAwakeRows
                    }
                    if let battery {
                        if !hidden.contains(.keepAwake) { Divider() }
                        Row {
                            Text("Battery")
                            Spacer()
                            Text(verbatim: battery.summary).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !hidden.contains(.sleepMac) || !hidden.contains(.lock) {
                RowGroup {
                    if !hidden.contains(.sleepMac) {
                        Row {
                            Button("Sleep Mac") { power.sleep() }.buttonStyle(.plain)
                            Spacer()
                        }
                    }
                    if !hidden.contains(.lock) {
                        if !hidden.contains(.sleepMac) { Divider() }
                        Row {
                            Button("Lock Screen") { power.lockScreen() }.buttonStyle(.plain)
                            Spacer()
                            Text("⌃⌘Q").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ErrorLabel(power.lastError)
        }
        .controlSize(.small)
        .modifier(BatteryRefresher(power: power))
    }

    @ViewBuilder private var keepAwakeRows: some View {
        Row {
            Text("Keep Awake")
            Spacer()
            if let endsAt = power.keepAwake?.endsAt {
                Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Toggle(
                "Keep Awake",
                isOn: Binding(get: { power.isKeepingAwake }, set: { _ in KeepAwakeSettings.toggle(power) })
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
        Divider()
        Row {
            Text("Duration")
            Spacer()
            Picker("Duration", selection: duration) {
                ForEach(PowerController.presets, id: \.self) { minutes in
                    Text(PowerController.title(minutes: minutes)).tag(minutes ?? 0)
                }
                Divider()
                if let current, let label = KeepAwakeSettings.customLabel(current) {
                    Text(label).tag(current)
                }
                Text("Custom…").tag(Self.customTag)
            }
            .labelsHidden()
            .fixedSize()
        }
        if editingCustom {
            CustomKeepAwakeEditor(power: power) { editingCustom = false }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        Divider()
        Row {
            Text("Keep Screens On")
            Spacer()
            Toggle(
                "Keep Screens On",
                isOn: Binding(
                    get: { keepScreensOn }, set: { KeepAwakeSettings.setKeepScreensOn($0, power: power) })
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
    }

    private static let customTag = -1

    /// The running duration, or the one the power button would use. 0 is "until turned off".
    private var current: Int? {
        power.isKeepingAwake ? power.keepAwake?.minutes ?? 0 : KeepAwakeSettings.minutes ?? 0
    }

    /// Picking a duration while Keep Awake is on restarts it with the new one.
    private var duration: Binding<Int> {
        Binding(
            get: { current ?? 0 },
            set: { tag in
                if tag == Self.customTag {
                    editingCustom = true
                    return
                }
                let minutes = tag > 0 ? tag : nil
                if power.isKeepingAwake {
                    KeepAwakeSettings.start(minutes: minutes, power: power)
                } else {
                    KeepAwakeSettings.minutes = minutes
                }
            })
    }
}
