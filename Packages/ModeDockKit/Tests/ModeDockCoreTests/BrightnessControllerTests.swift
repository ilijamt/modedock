import CoreGraphics
import DisplayKit
import Foundation
import Testing

@testable import ModeDockCore

@MainActor
private final class FakeBrightnessSystem: BrightnessSystem {
    var controllable: Set<CGDirectDisplayID>
    var levels: [CGDirectDisplayID: Double] = [:]
    var dimming: [CGDirectDisplayID: Double] = [:]
    var auto: [CGDirectDisplayID: Bool] = [1: true]
    private(set) var resetCount = 0

    init(controllable: Set<CGDirectDisplayID>, levels: [CGDirectDisplayID: Double]) {
        self.controllable = controllable
        self.levels = levels
    }

    func canControl(_ display: CGDirectDisplayID) -> Bool { controllable.contains(display) }
    func brightness(of display: CGDirectDisplayID) -> Double? { levels[display] }
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) throws { levels[display] = value }
    func setSoftwareDimming(_ value: Double, of display: CGDirectDisplayID) { dimming[display] = value }

    func resetSoftwareDimming() {
        resetCount += 1
        dimming = [:]
    }

    func autoBrightness(of display: CGDirectDisplayID) -> Bool? { auto[display] }

    func setAutoBrightness(_ enabled: Bool, of display: CGDirectDisplayID) throws {
        guard auto[display] != nil else { throw DisplayError.unsupported }
        auto[display] = enabled
    }
}

private actor FakeDDC: DDCControlling {
    var supported: Set<DisplayIdentity>
    var current: UInt16 = 40
    var readDelay: Duration = .zero
    private(set) var writes: [UInt16] = []

    init(supported: Set<DisplayIdentity>) { self.supported = supported }

    func refresh() {}

    func setReadDelay(_ delay: Duration) { readDelay = delay }

    func read(_ code: UInt8, from display: DisplayIdentity) async throws -> DDCPacket.Reply {
        if readDelay > .zero { try? await Task.sleep(for: readDelay) }
        guard supported.contains(display) else { throw DDCError.unavailable }
        return DDCPacket.Reply(current: current, maximum: 100)
    }

    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) async throws {
        guard supported.contains(display) else { throw DDCError.unavailable }
        writes.append(value)
        current = value
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
struct BrightnessControllerTests {
    private func make() async -> (BrightnessController, FakeBrightnessSystem, FakeDDC) {
        let system = FakeBrightnessSystem(controllable: [1], levels: [1: 0.62])
        let ddc = FakeDDC(supported: [external.identity])
        let controller = BrightnessController(system: system, ddc: ddc, ddcWriteInterval: .milliseconds(20))
        await controller.refresh(displays: [builtin, external, tv])
        return (controller, system, ddc)
    }

    @Test func picksBackendPerScreen() async {
        let (controller, _, _) = await make()
        #expect(controller.screens[1] == .init(value: 0.62, backend: .system, autoBrightness: true))
        #expect(controller.screens[5] == .init(value: 0.4, backend: .ddc(maximum: 100)))
        #expect(controller.screens[7] == .init(value: 1, backend: .software))
    }

    @Test func setsSystemBrightness() async {
        let (controller, system, _) = await make()
        controller.set(0.3, for: 1)
        #expect(system.levels[1] == 0.3)
    }

    @Test func coalescesDDCWritesWhileDragging() async throws {
        let (controller, _, ddc) = await make()
        for step in stride(from: 0.5, through: 0.9, by: 0.05) {
            controller.set(step, for: 5)
        }
        try await Task.sleep(for: .milliseconds(200))
        let writes = await ddc.writes
        #expect(writes.count < 9)
        // The final value is sent once more after the drag, in case the monitor missed it.
        #expect(writes.suffix(2) == [90, 90])
        #expect(controller.screens[5]?.value == 0.9)
    }

    @Test func softwareDimmingStopsAboveBlack() async {
        let (controller, system, _) = await make()
        controller.set(0, for: 7)
        #expect(system.dimming[7] == BrightnessController.softwareMinimum)
    }

    @Test func softwareDimmingIsReappliedAfterRefreshAndReset() async {
        let (controller, system, _) = await make()
        controller.set(0.5, for: 7)
        system.dimming = [:]  // macOS dropped the gamma table on a display change
        await controller.refresh(displays: [builtin, external, tv])
        #expect(system.dimming[7] == 0.5)

        controller.resetSoftwareDimming()
        #expect(system.resetCount == 1)
        #expect(controller.screens[7]?.value == 1)
    }

    @Test func togglesAutoBrightnessOnlyWhereSupported() async {
        let (controller, system, _) = await make()
        controller.setAutoBrightness(false, for: 1)
        #expect(system.auto[1] == false)
        #expect(controller.screens[1]?.autoBrightness == false)

        controller.setAutoBrightness(true, for: 5)
        #expect(controller.screens[5]?.autoBrightness == nil)
    }

    @Test func refreshDoesNotUndoAChangeMadeWhileReading() async throws {
        let (controller, _, ddc) = await make()
        await ddc.setReadDelay(.milliseconds(100))
        let refresh = Task { await controller.refresh(displays: [builtin, external, tv]) }
        try await Task.sleep(for: .milliseconds(20))
        controller.set(0.8, for: 5)
        controller.set(0.1, for: 1)
        await refresh.value
        #expect(controller.screens[5]?.value == 0.8)
        #expect(controller.screens[1]?.value == 0.1)
    }

    @Test func followsChangesMadeByAutomaticBrightness() async {
        let (controller, system, _) = await make()
        system.levels[1] = 0.9
        system.auto[1] = false
        controller.syncSystemBrightness()
        #expect(controller.screens[1] == .init(value: 0.9, backend: .system, autoBrightness: false))
    }

    @Test func resetRemovesDimmingAndTurnsAutoBackOn() async {
        let (controller, system, ddc) = await make()
        controller.set(0.3, for: 7)
        controller.setAutoBrightness(false, for: 1)

        for id: CGDirectDisplayID in [1, 5, 7] { controller.resetToDefault(for: id) }
        #expect(system.dimming[7] == 1)
        #expect(controller.screens[7]?.value == 1)
        #expect(system.auto[1] == true)
        #expect(await ddc.writes.isEmpty)
    }

    @Test func skipsScreensThatAreOff() async {
        let (controller, _, _) = await make()
        var off = external
        off.isEnabled = false
        await controller.refresh(displays: [builtin, off])
        #expect(controller.screens[5] == nil)
    }
}
