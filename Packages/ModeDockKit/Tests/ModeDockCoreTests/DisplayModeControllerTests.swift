import CoreGraphics
import DisplayKit
import Foundation
import Testing

@testable import ModeDockCore

@MainActor
private final class FakeConfigurator: DisplayConfiguring {
    var modes: [CGDirectDisplayID: [DisplayMode]]
    var current: [CGDirectDisplayID: DisplayMode]
    var originsByDisplay: [CGDirectDisplayID: CGPoint]
    var mirrored: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    private(set) var setModeCalls: [(CGDirectDisplayID, Int32)] = []

    init(
        modes: [CGDirectDisplayID: [DisplayMode]], current: [CGDirectDisplayID: DisplayMode],
        origins: [CGDirectDisplayID: CGPoint]
    ) {
        self.modes = modes
        self.current = current
        self.originsByDisplay = origins
    }

    func modes(for display: CGDirectDisplayID, includeDuplicates: Bool) -> [DisplayMode] { modes[display] ?? [] }
    func currentMode(for display: CGDirectDisplayID) -> DisplayMode? { current[display] }

    func setMode(_ mode: DisplayMode, for display: CGDirectDisplayID) throws {
        setModeCalls.append((display, mode.id))
        current[display] = mode
    }

    func origins(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGPoint] {
        originsByDisplay.filter { displays.contains($0.key) }
    }

    func setOrigins(_ origins: [CGDirectDisplayID: CGPoint]) throws { originsByDisplay = origins }

    func mirrors(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGDirectDisplayID] { mirrored }

    func setMirroring(_ displays: [CGDirectDisplayID], to source: CGDirectDisplayID?) throws {
        mirrored = [:]
        if let source {
            for display in displays where display != source { mirrored[display] = source }
        }
    }
}

private let native = DisplayMode(
    id: 1, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, isNative: true,
    isDefault: true)
private let small = DisplayMode(id: 2, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60)

@MainActor
struct DisplayModeControllerTests {
    private func make(timeout: Duration = .seconds(15)) -> (DisplayModeController, FakeConfigurator) {
        let configurator = FakeConfigurator(
            modes: [5: [native, small], 1: [native]], current: [5: native, 1: native],
            origins: [5: .zero, 1: CGPoint(x: -1512, y: 98)])
        let controller = DisplayModeController(
            configurator: configurator, defaults: makeDefaults(), confirmationTimeout: timeout)
        controller.refresh(displays: [external, builtin], showAllModes: false)
        return (controller, configurator)
    }

    @Test func loadsOptionsCurrentModeAndMain() {
        let (controller, _) = make()
        #expect(controller.screens[5]?.options.count == 2)
        #expect(controller.screens[5]?.current == native)
        #expect(controller.screens[5]?.isMain == true)
        #expect(controller.screens[1]?.isMain == false)
    }

    @Test func newModeAsksForConfirmationAndKeepRemembersIt() {
        let (controller, configurator) = make()
        var prompted = 0
        controller.onConfirmationNeeded = { _ in prompted += 1 }

        controller.select(small, for: 5)
        #expect(configurator.current[5] == small)
        #expect(controller.pending?.previous == native)
        #expect(prompted == 1)

        controller.confirm()
        #expect(controller.pending == nil)

        controller.select(native, for: 5)
        controller.select(small, for: 5)
        #expect(controller.pending == nil)
        #expect(prompted == 1)
    }

    @Test func resetGoesBackToTheDefaultModeWithoutAsking() {
        let (controller, configurator) = make()
        var prompted = 0
        controller.onConfirmationNeeded = { _ in prompted += 1 }
        controller.select(small, for: 5)
        controller.confirm()
        #expect(controller.screens[5]?.isAtDefault == false)

        controller.resetToDefault(5)
        #expect(configurator.current[5] == native)
        #expect(controller.screens[5]?.isAtDefault == true)
        #expect(controller.pending == nil)
        #expect(prompted == 1)
    }

    @Test func revertRestoresPreviousMode() {
        let (controller, configurator) = make()
        controller.select(small, for: 5)
        controller.revert()
        #expect(configurator.current[5] == native)
        #expect(controller.pending == nil)
    }

    @Test func revertsAutomaticallyAfterTimeout() async throws {
        let (controller, configurator) = make(timeout: .milliseconds(50))
        controller.select(small, for: 5)
        try await Task.sleep(for: .milliseconds(300))
        #expect(configurator.current[5] == native)
        #expect(controller.pending == nil)
    }

    @Test func ignoresSelectionWhileConfirmationPending() {
        let (controller, configurator) = make()
        controller.select(small, for: 5)
        controller.select(native, for: 5)
        #expect(configurator.setModeCalls.count == 1)
    }

    @Test func makeMainMovesOriginToTarget() {
        let (controller, configurator) = make()
        controller.makeMain(1)
        #expect(configurator.originsByDisplay[1] == .zero)
        #expect(controller.screens[1]?.isMain == true)
        #expect(controller.screens[5]?.isMain == false)
    }

    @Test func mirroringUsesMainScreenAsSource() {
        let (controller, configurator) = make()
        controller.setMirroring(true)
        #expect(configurator.mirrored == [1: 5])
        #expect(controller.isMirroring)

        controller.setMirroring(false)
        #expect(!controller.isMirroring)
    }
}
