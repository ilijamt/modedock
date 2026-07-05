import CoreGraphics
import DisplayKit
import Foundation
import Testing

@testable import ModeDockCore

@MainActor
private final class FakeDisplaySystem: DisplaySystem {
    var displays: [Display]

    init(_ displays: [Display]) { self.displays = displays }

    func onlineDisplays() -> [Display] { displays }

    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID) throws {
        guard let index = displays.firstIndex(where: { $0.id == display }) else {
            throw DisplayError.coreGraphics(1001)
        }
        displays[index].isEnabled = enabled
    }

    func sleepAllDisplays() throws {}
}

private actor NoDDC: DDCControlling {
    func refresh() {}
    func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply { throw DDCError.unavailable }
    func capabilities(of display: DisplayIdentity) throws -> String { throw DDCError.unavailable }
    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) throws {
        throw DDCError.unavailable
    }
}

@MainActor
private final class FakeConfigurator: DisplayConfiguring {
    var modes: [CGDirectDisplayID: [DisplayMode]]
    var current: [CGDirectDisplayID: DisplayMode]
    var originsByDisplay: [CGDirectDisplayID: CGPoint]
    var mirrored: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    private(set) var setModeCalls = 0
    private(set) var setOriginsCalls = 0

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
        setModeCalls += 1
        current[display] = mode
    }

    func origins(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGPoint] {
        originsByDisplay.filter { displays.contains($0.key) }
    }

    func setOrigins(_ origins: [CGDirectDisplayID: CGPoint]) throws {
        setOriginsCalls += 1
        originsByDisplay.merge(origins) { _, new in new }
    }

    func mirrors(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGDirectDisplayID] {
        mirrored.filter { displays.contains($0.key) }
    }

    func setMirroring(_ displays: [CGDirectDisplayID], to source: CGDirectDisplayID?) throws {
        mirrored = [:]
        if let source {
            for display in displays where display != source { mirrored[display] = source }
        }
    }
}

@MainActor
private final class FakeBrightnessSystem: BrightnessSystem {
    var levels: [CGDirectDisplayID: Double] = [1: 0.8, 5: 0.6, 7: 0.5]

    func canControl(_ display: CGDirectDisplayID) -> Bool { true }
    func brightness(of display: CGDirectDisplayID) -> Double? { levels[display] }
    func setBrightness(_ value: Double, of display: CGDirectDisplayID) throws { levels[display] = value }
    func setSoftwareDimming(_ value: Double, of display: CGDirectDisplayID) {}
    func resetSoftwareDimming() {}
    func autoBrightness(of display: CGDirectDisplayID) -> Bool? { nil }
    func setAutoBrightness(_ enabled: Bool, of display: CGDirectDisplayID) throws {}
}

private let large = DisplayMode(
    id: 1, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60, isNative: true)
private let small = DisplayMode(id: 2, width: 1280, height: 720, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60)
private let laptop = DisplayMode(
    id: 3, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 120, isNative: true)

@MainActor
private struct Setup {
    let system: FakeDisplaySystem
    let configurator: FakeConfigurator
    let brightnessSystem: FakeBrightnessSystem
    let screens: ScreenController
    let modes: DisplayModeController
    let brightness: BrightnessController
    let profiles: ProfileController
    let defaults: UserDefaults

    init(_ displays: [Display] = [builtin, external], defaults: UserDefaults = makeDefaults()) async {
        system = FakeDisplaySystem(displays)
        configurator = FakeConfigurator(
            modes: [1: [laptop], 5: [large, small], 7: [large]],
            current: [1: laptop, 5: large, 7: large],
            origins: [5: .zero, 1: CGPoint(x: -1512, y: 98), 7: CGPoint(x: 1920, y: 0)])
        brightnessSystem = FakeBrightnessSystem()
        self.defaults = defaults
        screens = ScreenController(system: system, ddc: NoDDC(), defaults: defaults)
        modes = DisplayModeController(configurator: configurator, defaults: defaults)
        brightness = BrightnessController(system: brightnessSystem, ddc: NoDDC())
        profiles = ProfileController(
            screens: screens, modes: modes, brightness: brightness, configurator: configurator,
            defaults: defaults, settleDelay: .zero)
        await screens.start()
        await reload()
    }

    /// What the app does after the screens change.
    func reload() async {
        let displays = screens.screens.map(\.display)
        modes.refresh(displays: displays, showAllModes: false)
        await brightness.refresh(displays: displays)
    }
}

@MainActor
struct ProfileControllerTests {
    @Test func captureSavesEveryScreen() async {
        let setup = await Setup()
        let profile = setup.profiles.capture(name: "Desk")

        #expect(profile.screens.count == 2)
        let saved = profile.screens.first { $0.identity == external.identity }
        #expect(saved?.isEnabled == true)
        #expect(saved?.modeKey == large.key)
        #expect(saved?.origin == .zero)
        #expect(saved?.brightness == 0.6)
        #expect(setup.profiles.isActive(profile))
    }

    @Test func applyRestoresTheCapturedSetup() async {
        let setup = await Setup()
        let profile = setup.profiles.capture(name: "Desk")

        // Change everything the profile covers.
        setup.screens.setEnabled(false, screen: 1)
        setup.configurator.current[5] = small
        setup.configurator.originsByDisplay[5] = CGPoint(x: 100, y: 0)
        setup.brightnessSystem.levels[5] = 0.2
        await setup.reload()
        #expect(!setup.profiles.isActive(profile))

        await setup.profiles.apply(profile)

        #expect(setup.system.displays.filter { !$0.isEnabled }.isEmpty)
        #expect(setup.configurator.current[5] == large)
        #expect(setup.configurator.originsByDisplay[5] == .zero)
        #expect(setup.configurator.originsByDisplay[1] == CGPoint(x: -1512, y: 98))
        #expect(setup.brightnessSystem.levels[5] == 0.6)
        #expect(setup.modes.pending == nil)
        #expect(setup.profiles.lastError == nil)
        #expect(setup.profiles.isActive(profile))
    }

    @Test func applyingTheCurrentSetupChangesNothing() async {
        let setup = await Setup()
        let profile = setup.profiles.capture(name: "Desk")

        await setup.profiles.apply(profile)

        #expect(setup.configurator.setModeCalls == 0)
        #expect(setup.configurator.setOriginsCalls == 0)
        #expect(setup.profiles.lastError == nil)
    }

    @Test func applyTurnsOffScreensTheProfileWantsOff() async {
        let setup = await Setup()
        setup.screens.setEnabled(false, screen: 1)
        await setup.reload()
        let profile = setup.profiles.capture(name: "Clamshell")
        #expect(profile.screens.first { $0.identity == builtin.identity }?.isEnabled == false)

        setup.screens.setEnabled(true, screen: 1)
        await setup.reload()
        await setup.profiles.apply(profile)

        #expect(setup.system.displays.first { $0.id == 1 }?.isEnabled == false)
        #expect(setup.profiles.isActive(profile))
    }

    @Test func applySkipsScreensThatAreNotConnected() async {
        let setup = await Setup()
        var profile = setup.profiles.capture(name: "Desk and TV")
        profile.screens.append(
            ProfileScreen(
                identity: tv.identity, name: "TV", isEnabled: true, modeKey: large.key, originX: 1920, originY: 0,
                brightness: 0.3))
        setup.configurator.current[5] = small
        await setup.reload()

        await setup.profiles.apply(profile)

        #expect(setup.configurator.current[5] == large)
        #expect(setup.configurator.originsByDisplay[5] == .zero)
        #expect(setup.profiles.lastError == nil)
        // The TV is part of the profile, so this setup isn't it.
        #expect(!setup.profiles.isActive(profile))
    }

    @Test func applyRestoresMirroring() async {
        let setup = await Setup()
        setup.modes.setMirroring(true)
        let profile = setup.profiles.capture(name: "Presenting")
        #expect(profile.mirroring)

        setup.modes.setMirroring(false)
        #expect(!setup.profiles.isActive(profile))
        await setup.profiles.apply(profile)

        #expect(setup.configurator.mirrored == [1: 5])
        #expect(setup.profiles.isActive(profile))
    }

    @Test func updateKeepsNameAndOptions() async {
        let setup = await Setup()
        let profile = setup.profiles.capture(name: "Desk")
        setup.profiles.setAutoApply(true, for: profile.id)
        setup.configurator.current[5] = small

        setup.profiles.update(profile.id)

        let updated = setup.profiles.profiles.first
        #expect(updated?.id == profile.id)
        #expect(updated?.name == "Desk")
        #expect(updated?.autoApply == true)
        #expect(updated?.screens.first { $0.identity == external.identity }?.modeKey == small.key)
    }

    @Test func profilesArePersisted() async {
        let defaults = makeDefaults()
        let setup = await Setup(defaults: defaults)
        let desk = setup.profiles.capture(name: "Desk")
        setup.profiles.capture(name: "Other")
        setup.profiles.rename(desk.id, to: "Work")
        setup.profiles.setAutoApply(true, for: desk.id)
        setup.profiles.delete(setup.profiles.profiles[1].id)

        let reloaded = ProfileController(
            screens: setup.screens, modes: setup.modes, brightness: setup.brightness,
            configurator: setup.configurator, defaults: defaults)
        #expect(reloaded.profiles.count == 1)
        #expect(reloaded.profiles.first?.name == "Work")
        #expect(reloaded.profiles.first?.autoApply == true)
        #expect(reloaded.profiles.first?.screens == desk.screens)
    }

    @Test func autoApplyRunsOnceWhenItsScreensAreConnected() async {
        let setup = await Setup([builtin, external, tv])
        setup.configurator.current[5] = small
        await setup.reload()
        var profile = setup.profiles.capture(name: "Docked")
        setup.profiles.setAutoApply(true, for: profile.id)
        profile = setup.profiles.profiles[0]

        // Undock: the TV goes away and the external monitor changes mode.
        setup.system.displays.removeAll { $0.id == 7 }
        await setup.screens.displaysChanged()
        await setup.profiles.autoApplyIfNeeded()
        setup.configurator.current[5] = large
        await setup.reload()

        // Dock again: the profile comes back.
        setup.system.displays.append(tv)
        await setup.screens.displaysChanged()
        await setup.reload()
        await setup.profiles.autoApplyIfNeeded()
        #expect(setup.configurator.current[5] == small)

        // Same screens, so a later change by hand stays.
        let calls = setup.configurator.setModeCalls
        setup.configurator.current[5] = large
        await setup.profiles.autoApplyIfNeeded()
        #expect(setup.configurator.setModeCalls == calls)
        #expect(setup.configurator.current[5] == large)
    }

    @Test func onlyOneProfileAppliesAutomaticallyForTheSameScreens() async {
        let setup = await Setup()
        let first = setup.profiles.capture(name: "Bright")
        let second = setup.profiles.capture(name: "Dim")
        setup.profiles.setAutoApply(true, for: first.id)
        #expect(setup.profiles.automaticProfile(sharingScreensWith: second.id)?.id == first.id)

        setup.profiles.setAutoApply(true, for: second.id)

        #expect(setup.profiles.profiles.map(\.autoApply) == [false, true])
        #expect(setup.profiles.automaticProfile(sharingScreensWith: second.id) == nil)
    }

    @Test func autoApplyRestoresBrightnessWhenScreensReconnect() async {
        let setup = await Setup([builtin, external, tv])
        let profile = setup.profiles.capture(name: "Docked")
        setup.profiles.setAutoApply(true, for: profile.id)
        await setup.profiles.autoApplyIfNeeded()

        // Same resolutions, so the profile still counts as current, but the brightness changed.
        setup.system.displays.removeAll { $0.id == 7 }
        await setup.screens.displaysChanged()
        await setup.profiles.autoApplyIfNeeded()
        setup.brightnessSystem.levels[5] = 0.2
        await setup.reload()

        setup.system.displays.append(tv)
        await setup.screens.displaysChanged()
        await setup.reload()
        await setup.profiles.autoApplyIfNeeded()

        #expect(setup.brightnessSystem.levels[5] == 0.6)
    }

    @Test func currentProfileFollowsBrightness() async {
        let setup = await Setup()
        let bright = setup.profiles.capture(name: "Bright")
        setup.brightnessSystem.levels[5] = 0.2
        await setup.reload()
        let dim = setup.profiles.capture(name: "Dim")
        #expect(setup.profiles.currentProfile?.id == dim.id)

        await setup.profiles.apply(bright)
        #expect(setup.profiles.currentProfile?.id == bright.id)

        // Drifted away from both.
        setup.brightnessSystem.levels[5] = 0.4
        await setup.reload()
        #expect(setup.profiles.currentProfile == nil)
    }

    @Test func lastUsedWinsWhenSeveralMatch() async {
        let setup = await Setup()
        let first = setup.profiles.capture(name: "A")
        let second = setup.profiles.capture(name: "B")
        #expect(setup.profiles.currentProfile?.id == second.id)

        await setup.profiles.apply(first)
        #expect(setup.profiles.currentProfile?.id == first.id)
    }

    @Test func moveReordersProfiles() async {
        let setup = await Setup()
        let first = setup.profiles.capture(name: "A")
        setup.profiles.capture(name: "B")

        setup.profiles.move(first.id, by: 1)
        #expect(setup.profiles.profiles.map(\.name) == ["B", "A"])

        setup.profiles.move(first.id, by: 1)
        #expect(setup.profiles.profiles.map(\.name) == ["B", "A"])
    }

    @Test func moveToPutsAProfileWhereTheTargetIs() async {
        let setup = await Setup()
        let a = setup.profiles.capture(name: "A")
        setup.profiles.capture(name: "B")
        let c = setup.profiles.capture(name: "C")

        setup.profiles.move(c.id, to: a.id)
        #expect(setup.profiles.profiles.map(\.name) == ["C", "A", "B"])

        setup.profiles.move(c.id, to: setup.profiles.profiles[2].id)
        #expect(setup.profiles.profiles.map(\.name) == ["A", "B", "C"])
    }

    @Test func autoApplyIgnoresProfilesForOtherScreens() async {
        let setup = await Setup()
        let profile = setup.profiles.capture(name: "Desk")
        setup.profiles.setAutoApply(true, for: profile.id)
        setup.configurator.current[5] = small

        setup.system.displays.append(tv)
        await setup.screens.displaysChanged()
        await setup.profiles.autoApplyIfNeeded()

        #expect(setup.configurator.current[5] == small)
    }
}
