import Foundation
import IOKit.ps
import Testing

@testable import ModeDockCore

@MainActor
private final class FakePowerSystem: PowerSystem {
    var refuse = false
    var active: [UInt32: Bool] = [:]
    private var nextID: UInt32 = 1
    private(set) var sleeps = 0
    private(set) var locks = 0
    var status: BatteryStatus?

    func preventSleep(keepScreensOn: Bool, reason: String) -> UInt32? {
        guard !refuse else { return nil }
        defer { nextID += 1 }
        active[nextID] = keepScreensOn
        return nextID
    }

    func allowSleep(_ assertion: UInt32) { active[assertion] = nil }
    func sleep() throws { sleeps += 1 }
    func lockScreen() throws { locks += 1 }
    func battery() -> BatteryStatus? { status }
}

@MainActor
struct PowerControllerTests {
    @Test func keepAwakeHoldsOneAssertionUntilStopped() {
        let system = FakePowerSystem()
        let controller = PowerController(system: system)

        controller.startKeepAwake(minutes: nil, keepScreensOn: true)
        #expect(controller.keepAwake == .init(minutes: nil, endsAt: nil))
        #expect(system.active == [1: true])

        // Starting again replaces the running one rather than stacking a second assertion.
        controller.startKeepAwake(minutes: 60, keepScreensOn: false)
        #expect(system.active == [2: false])
        let endsAt = try? #require(controller.keepAwake?.endsAt)
        #expect(abs((endsAt ?? .distantPast).timeIntervalSinceNow - 3600) < 5)

        controller.stopKeepAwake()
        #expect(controller.keepAwake == nil)
        #expect(system.active.isEmpty)
    }

    @Test func switchingScreensOptionKeepsTheTimer() {
        let system = FakePowerSystem()
        let controller = PowerController(system: system)
        controller.startKeepAwake(minutes: 60, keepScreensOn: true)
        let before = controller.keepAwake

        controller.setKeepScreensOn(false)
        #expect(system.active == [2: false])
        #expect(controller.keepAwake == before)
    }

    @Test func durationTitles() {
        #expect(PowerController.title(minutes: nil) == "Until turned off")
        #expect(PowerController.title(minutes: 45) == "45 minutes")
        #expect(PowerController.title(minutes: 60) == "1 hour")
        #expect(PowerController.title(minutes: 240) == "4 hours")
        #expect(PowerController.title(minutes: 95) == "1 h 35 min")
    }

    @Test(arguments: [
        ("90", 90), ("45m", 45), ("45 min", 45), ("2h", 120), ("2 hours", 120), ("1h30", 90),
        ("1h 30m", 90), ("1:30", 90), ("1.5h", 90), ("1,5h", 90), ("0:05", 5),
    ])
    func parsesTypedDurations(text: String, minutes: Int) {
        #expect(PowerController.minutes(from: text) == minutes)
    }

    @Test(arguments: ["", "abc", "0", "h", "m", "-5", "200h"])
    func rejectsInvalidDurations(text: String) {
        #expect(PowerController.minutes(from: text) == nil)
    }

    @Test func minutesUntilTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 14, minute: 0)))
        let later = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 17, minute: 30)))
        let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9)))
        #expect(PowerController.minutes(until: later, from: now, calendar: calendar) == 210)
        #expect(PowerController.minutes(until: earlier, from: now, calendar: calendar) == 19 * 60)
    }

    @Test func reportsRefusedAssertion() {
        let system = FakePowerSystem()
        system.refuse = true
        let controller = PowerController(system: system)
        controller.startKeepAwake(minutes: 15, keepScreensOn: true)
        #expect(controller.keepAwake == nil)
        #expect(controller.lastError != nil)
    }

    @Test func sleepAndLock() {
        let system = FakePowerSystem()
        let controller = PowerController(system: system)
        controller.sleep()
        controller.lockScreen()
        #expect(system.sleeps == 1)
        #expect(system.locks == 1)
    }

    @Test func readsBattery() {
        let system = FakePowerSystem()
        system.status = BatteryStatus(percent: 80, state: .charging, minutesRemaining: 30)
        let controller = PowerController(system: system)
        controller.refreshBattery()
        #expect(controller.battery == system.status)
    }
}

struct BatteryStatusTests {
    private func description(
        current: Int = 50, ac: Bool, charging: Bool = false, charged: Bool = false,
        toEmpty: Int = -1, toFull: Int = -1, type: String = kIOPSInternalBatteryType
    ) -> [String: Any] {
        [
            kIOPSTypeKey: type, kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: ac ? kIOPSACPowerValue : kIOPSBatteryPowerValue,
            kIOPSIsChargingKey: charging, kIOPSIsChargedKey: charged,
            kIOPSTimeToEmptyKey: toEmpty, kIOPSTimeToFullChargeKey: toFull,
        ]
    }

    @Test func onBatteryWithEstimate() {
        #expect(
            BatteryStatus(description: description(current: 64, ac: false, toEmpty: 185))
                == BatteryStatus(percent: 64, state: .onBattery, minutesRemaining: 185))
    }

    @Test func stillCalculating() {
        #expect(BatteryStatus(description: description(ac: false))?.minutesRemaining == nil)
    }

    @Test func chargingChargedAndHeld() {
        #expect(
            BatteryStatus(description: description(ac: true, charging: true, toFull: 40))
                == BatteryStatus(percent: 50, state: .charging, minutesRemaining: 40))
        #expect(BatteryStatus(description: description(current: 100, ac: true, charged: true))?.state == .charged)
        #expect(BatteryStatus(description: description(current: 80, ac: true))?.state == .notCharging)
    }

    @Test func ignoresOtherPowerSources() {
        #expect(BatteryStatus(description: description(ac: true, type: kIOPSUPSType)) == nil)
    }
}
