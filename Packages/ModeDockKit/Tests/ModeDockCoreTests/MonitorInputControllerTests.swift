import CoreGraphics
import DisplayKit
import Testing

@testable import ModeDockCore

private actor FakeInputDDC: DDCControlling {
    var current: UInt16
    var capabilities: String?
    private(set) var capabilityReads = 0
    private(set) var writes: [UInt16] = []

    init(current: UInt16, capabilities: String?) {
        self.current = current
        self.capabilities = capabilities
    }

    func refresh() {}

    func setCapabilities(_ capabilities: String?) { self.capabilities = capabilities }

    func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply {
        DDCPacket.Reply(current: current, maximum: 0)
    }

    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) throws {
        writes.append(value)
        current = value
    }

    func capabilities(of display: DisplayIdentity) throws -> String {
        capabilityReads += 1
        guard let capabilities else { throw DDCError.badReply }
        return capabilities
    }
}

private let monitor = Display(
    id: 5, identity: DisplayIdentity(vendor: 19501, model: 29046, serial: 42), name: "LS28", isBuiltin: false,
    isEnabled: true)
private let laptop = Display(
    id: 1, identity: DisplayIdentity(vendor: 1552, model: 1, serial: 1), name: "Built-in", isBuiltin: true,
    isEnabled: true)

@MainActor
struct MonitorInputControllerTests {
    @Test func listsInputsFromCapabilitiesOnce() async {
        let ddc = FakeInputDDC(current: 0x0103, capabilities: "(vcp(10 60(01 03) D6(01 04)))")
        let controller = MonitorInputController(ddc: ddc)
        await controller.refresh(displays: [laptop, monitor])
        await controller.refresh(displays: [laptop, monitor])
        #expect(controller.screens[5] == .init(current: 0x03, available: [0x01, 0x03]))
        #expect(controller.screens[1] == nil)
        #expect(await ddc.capabilityReads == 1)
    }

    @Test func fallsBackToCommonInputs() async {
        let controller = MonitorInputController(ddc: FakeInputDDC(current: 0x1B, capabilities: nil))
        await controller.refresh(displays: [monitor])
        #expect(controller.screens[5]?.available == [0x1B] + MonitorInputController.commonInputs)
    }

    @Test func retriesCapabilitiesAfterAFailedRead() async {
        let ddc = FakeInputDDC(current: 0x0F, capabilities: nil)
        let controller = MonitorInputController(ddc: ddc)
        await controller.refresh(displays: [monitor])
        await ddc.setCapabilities("vcp(60(0F 10 11 1B))")
        await controller.refresh(displays: [monitor])
        #expect(controller.screens[5]?.available == [0x0F, 0x10, 0x11, 0x1B])
    }

    @Test func stopsRetryingCapabilitiesThatKeepFailing() async {
        let ddc = FakeInputDDC(current: 0x0F, capabilities: nil)
        let controller = MonitorInputController(ddc: ddc)
        for _ in 0..<5 { await controller.refresh(displays: [monitor]) }
        #expect(await ddc.capabilityReads == MonitorInputController.capabilityAttempts)
        #expect(controller.screens[5]?.available == MonitorInputController.commonInputs)
    }

    @Test func switchesInput() async {
        let ddc = FakeInputDDC(current: 0x0F, capabilities: "vcp(60(0F 11))")
        let controller = MonitorInputController(ddc: ddc)
        await controller.refresh(displays: [monitor])
        await controller.select(0x11, for: 5)
        await controller.select(0x11, for: 5)
        #expect(await ddc.writes == [0x11])
        #expect(controller.screens[5]?.current == 0x11)
    }
}
