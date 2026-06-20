import CoreGraphics
import DisplayKit
import Foundation
import Testing

@testable import ModeDockCore

@MainActor
private final class FakeDisplaySystem: DisplaySystem {
    var displays: [Display]
    var failNextChange = false
    /// Mimics macOS dropping a disabled display from the online list.
    var hideDisabled = false
    private(set) var sleepCount = 0

    init(_ displays: [Display]) { self.displays = displays }

    func onlineDisplays() -> [Display] {
        hideDisabled ? displays.filter(\.isEnabled) : displays
    }

    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        if failNextChange {
            failNextChange = false
            throw DisplayError.coreGraphics(1000)
        }
        guard let index = displays.firstIndex(where: { $0.id == display }) else {
            throw DisplayError.coreGraphics(1001)
        }
        displays[index].isEnabled = enabled
    }

    func sleepAllDisplays() throws { sleepCount += 1 }
}

private actor FakeDDC: DDCControlling {
    var supported: Set<DisplayIdentity>
    private(set) var writes: [(DisplayIdentity, UInt16)] = []

    init(supported: Set<DisplayIdentity>) { self.supported = supported }

    func refresh() {}

    func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply {
        guard supported.contains(display) else { throw DDCError.unavailable }
        return DDCPacket.Reply(current: 1, maximum: 5)
    }

    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) throws {
        guard supported.contains(display) else { throw DDCError.unavailable }
        writes.append((display, value))
    }
}

@MainActor
struct ScreenControllerTests {
    private func make(
        _ displays: [Display] = [builtin, external],
        ddc: Set<DisplayIdentity> = [external.identity],
        defaults: UserDefaults? = nil
    ) async -> (ScreenController, FakeDisplaySystem, FakeDDC) {
        let system = FakeDisplaySystem(displays)
        let fakeDDC = FakeDDC(supported: ddc)
        let controller = ScreenController(system: system, ddc: fakeDDC, defaults: defaults ?? makeDefaults())
        await controller.start()
        return (controller, system, fakeDDC)
    }

    @Test func listsBuiltinFirstAndDetectsDDC() async {
        let (controller, _, _) = await make([external, builtin])
        #expect(controller.screens.map(\.id) == [1, 5])
        #expect(controller.screens.map(\.supportsDDC) == [false, true])
    }

    @Test func disablesAndReenables() async {
        let (controller, system, _) = await make()
        controller.setEnabled(false, screen: 5)
        #expect(system.displays[1].isEnabled == false)
        #expect(controller.screens.first { $0.id == 5 }?.display.isEnabled == false)

        controller.setEnabled(true, screen: 5)
        #expect(system.displays[1].isEnabled)
    }

    @Test func refusesToDisableLastEnabledDisplay() async {
        let (controller, system, _) = await make()
        controller.setEnabled(false, screen: 5)
        #expect(controller.screens.first { $0.id == 1 }?.canDisable == false)

        controller.setEnabled(false, screen: 1)
        #expect(system.displays[0].isEnabled)
        #expect(controller.lastError != nil)
    }

    @Test func keepsListingDisabledDisplayThatLeftOnlineList() async {
        let (controller, system, _) = await make()
        system.hideDisabled = true
        controller.setEnabled(false, screen: 5)
        #expect(controller.screens.contains { $0.id == 5 && !$0.display.isEnabled })

        await controller.restoreAll()
        #expect(system.displays.allSatisfy { $0.isEnabled })
    }

    @Test func reportsFailureWithoutTrackingDisplay() async {
        let (controller, system, _) = await make()
        system.failNextChange = true
        controller.setEnabled(false, screen: 5)
        #expect(controller.lastError != nil)
        #expect(system.displays[1].isEnabled)
    }

    @Test func reenablesDisplaysLeftOffByPreviousRun() async {
        let defaults = makeDefaults()
        let (first, system, _) = await make(defaults: defaults)
        first.setEnabled(false, screen: 5)
        #expect(!system.displays[1].isEnabled)

        // A new controller (next launch) with the same defaults turns it back on.
        let next = ScreenController(system: system, ddc: FakeDDC(supported: []), defaults: defaults)
        await next.start()
        #expect(system.displays[1].isEnabled)
    }

    @Test func standbyAndRestoreWakesMonitor() async {
        let (controller, _, ddc) = await make()
        await controller.setStandby(true, screen: 5)
        #expect(controller.screens.first { $0.id == 5 }?.isInStandby == true)

        await controller.restoreAll()
        let values = await ddc.writes.map(\.1)
        #expect(values == [DDCPacket.PowerMode.off, DDCPacket.PowerMode.on])
        #expect(controller.screens.first { $0.id == 5 }?.isInStandby == false)
    }

    @Test func standbyWithoutDDCReportsError() async {
        let (controller, _, _) = await make(ddc: [])
        await controller.setStandby(true, screen: 5)
        #expect(controller.lastError != nil)
        #expect(controller.screens.first { $0.id == 5 }?.isInStandby == false)
    }

    @Test func unpluggingLastScreenTurnsDisabledScreensBackOn() async {
        let (controller, system, _) = await make()
        controller.setEnabled(false, screen: 1)
        #expect(!system.displays[0].isEnabled)

        system.displays.removeAll { $0.id == 5 }
        await controller.displaysChanged()
        #expect(system.displays[0].isEnabled)
    }

    @Test func placeholderDisplayDoesNotCountAsScreen() async {
        let (controller, system, _) = await make()
        controller.setEnabled(false, screen: 1)

        system.displays.removeAll { $0.id == 5 }
        system.displays.append(
            Display(
                id: 9, identity: DisplayIdentity(vendor: 0x756E_6B6E, model: 0, serial: 0),
                name: "Placeholder", isBuiltin: false, isEnabled: true))
        await controller.displaysChanged()
        #expect(system.displays[0].isEnabled)
    }

    @Test func sleepingScreensDoNotTriggerRestore() async {
        let (controller, system, _) = await make()
        controller.setEnabled(false, screen: 1)
        // Display sleep: the external is online but inactive, and ModeDock didn't turn it off.
        system.displays[1].isEnabled = false
        await controller.displaysChanged()
        #expect(!system.displays[0].isEnabled)
    }

    @Test func sleepAllDisplays() async {
        let (controller, system, _) = await make()
        controller.sleepAllDisplays()
        #expect(system.sleepCount == 1)
    }
}
