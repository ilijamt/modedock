import Foundation
import Testing

@testable import ModeDockCore

@MainActor
final class FakeUtilitySystem: UtilitySystem {
    var current = UtilityState(darkMode: true, dockAutoHide: false, nightShift: false, trueTone: nil)
    var volumes = [URL(fileURLWithPath: "/Volumes/Backup"), URL(fileURLWithPath: "/Volumes/Camera")]
    var busy: Set<String> = []
    var trashEmptied = 0

    func state() -> UtilityState {
        var state = current
        state.ejectableVolumes = volumes.count
        return state
    }

    func setDarkMode(_ on: Bool) throws { current.darkMode = on }
    func setDockAutoHide(_ on: Bool) throws { current.dockAutoHide = on }
    func setDesktopIcons(_ shown: Bool) throws { current.desktopIcons = shown }
    func setHiddenFiles(_ shown: Bool) throws { current.hiddenFiles = shown }
    func setNightShift(_ on: Bool) throws { current.nightShift = on }
    func setTrueTone(_ on: Bool) throws { throw UtilityError.unsupported }
    func emptyTrash() throws { trashEmptied += 1 }
    func ejectableVolumes() -> [URL] { volumes }

    func eject(_ volume: URL) async throws {
        if busy.contains(volume.lastPathComponent) { throw UtilityError.failed("busy") }
        volumes.removeAll { $0 == volume }
    }
}

@MainActor
struct UtilitiesControllerTests {
    @Test func togglesUpdateTheState() {
        let system = FakeUtilitySystem()
        let controller = UtilitiesController(system: system)
        controller.refresh()
        #expect(controller.state.darkMode == true)

        controller.setDarkMode(false)
        controller.setDockAutoHide(true)
        controller.setHiddenFiles(true)
        controller.setNightShift(true)
        #expect(controller.state.darkMode == false)
        #expect(controller.state.dockAutoHide == true)
        #expect(controller.state.hiddenFiles == true)
        #expect(controller.state.nightShift == true)
        #expect(controller.lastError == nil)
    }

    @Test func reportsUnsupportedToggles() {
        let controller = UtilitiesController(system: FakeUtilitySystem())
        controller.setTrueTone(true)
        #expect(controller.lastError != nil)
        controller.emptyTrash()
        #expect(controller.lastError == nil)
    }

    @Test func ejectAllNamesTheVolumesThatStayed() async {
        let system = FakeUtilitySystem()
        system.busy = ["Camera"]
        let controller = UtilitiesController(system: system)
        await controller.ejectAll()
        #expect(system.volumes.map(\.lastPathComponent) == ["Camera"])
        #expect(controller.state.ejectableVolumes == 1)
        #expect(controller.lastError?.contains("Camera") == true)
        #expect(controller.isEjecting == false)
    }
}
