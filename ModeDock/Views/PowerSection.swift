import ModeDockCore
import SwiftUI

/// Keep Awake preferences shared by every panel style.
@MainActor
enum KeepAwakeSettings {
    /// The duration used when Keep Awake is switched on; the last one picked.
    static var duration: PowerController.Duration {
        PowerController.Duration(rawValue: UserDefaults.standard.integer(forKey: SettingsKey.keepAwakeDuration))
            ?? .indefinitely
    }

    static var keepScreensOn: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.keepScreensOn) as? Bool ?? true
    }

    static func start(_ duration: PowerController.Duration, power: PowerController) {
        UserDefaults.standard.set(duration.rawValue, forKey: SettingsKey.keepAwakeDuration)
        power.startKeepAwake(duration, keepScreensOn: keepScreensOn)
    }

    static func setKeepScreensOn(_ on: Bool, power: PowerController) {
        UserDefaults.standard.set(on, forKey: SettingsKey.keepScreensOn)
        power.setKeepScreensOn(on)
    }

    static func toggle(_ power: PowerController) {
        if power.isKeepingAwake { power.stopKeepAwake() } else { start(duration, power: power) }
    }
}

extension BatteryStatus {
    var summary: String {
        var parts = ["\(percent)%"]
        switch state {
        case .onBattery: if let time { parts.append("\(time) left") }
        case .charging: parts.append(time.map { "\($0) until full" } ?? "Charging")
        case .charged: parts.append("Charged")
        case .notCharging: parts.append("Not charging")
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
                HStack(spacing: 8) {
                    if !hidden.contains(.sleepMac) {
                        ActionTile(title: "Sleep Mac", systemImage: "powersleep") { power.sleep() }
                            .help("Put the Mac to sleep now.")
                    }
                    if !hidden.contains(.lock) {
                        ActionTile(title: "Lock", systemImage: "lock.fill") { power.lockScreen() }
                            .help("Lock the screen (⌃⌘Q).")
                    }
                }
            }

            if let error = power.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(BatteryRefresher(power: power))
    }

    private var keepAwakeCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(power.isKeepingAwake ? .primary : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keep Awake").font(.system(size: 13, weight: .medium))
                    KeepAwakeMenu(power: power)
                }
                Spacer(minLength: 4)
                CircleToggle(systemImage: "power", isOn: power.isKeepingAwake) {
                    KeepAwakeSettings.toggle(power)
                }
                .help(power.isKeepingAwake ? "Let the Mac sleep again." : "Stop the Mac from going to sleep.")
            }
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
    @AppStorage(SettingsKey.keepScreensOn) private var keepScreensOn = true

    var body: some View {
        Menu {
            ForEach(PowerController.Duration.allCases) { duration in
                Button(power.keepAwake?.duration == duration ? "✓ \(duration.title)" : duration.title) {
                    KeepAwakeSettings.start(duration, power: power)
                }
            }
            Divider()
            Toggle("Keep Screens On", isOn: $keepScreensOn)
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
        .help("Choose how long to keep the Mac awake")
        .onChange(of: keepScreensOn) { power.setKeepScreensOn(keepScreensOn) }
    }

    @ViewBuilder private var status: some View {
        if let keepAwake = power.keepAwake {
            if let endsAt = keepAwake.endsAt {
                HStack(spacing: 0) {
                    Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true).monospacedDigit()
                    Text(verbatim: " left")
                }
            } else {
                Text("On until turned off")
            }
        } else {
            Text("Off")
        }
    }
}

/// The Power section in the Rows style.
struct RowsPowerSection: View {
    let power: PowerController
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

            if let error = power.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
        .modifier(BatteryRefresher(power: power))
        .onChange(of: keepScreensOn) { power.setKeepScreensOn(keepScreensOn) }
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
                ForEach(PowerController.Duration.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        Divider()
        Row {
            Text("Keep Screens On")
            Spacer()
            Toggle("Keep Screens On", isOn: $keepScreensOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    /// Picking a duration while Keep Awake is on restarts it with the new one.
    private var duration: Binding<PowerController.Duration> {
        Binding(
            get: { power.keepAwake?.duration ?? KeepAwakeSettings.duration },
            set: { duration in
                if power.isKeepingAwake {
                    KeepAwakeSettings.start(duration, power: power)
                } else {
                    UserDefaults.standard.set(duration.rawValue, forKey: SettingsKey.keepAwakeDuration)
                }
            })
    }
}
