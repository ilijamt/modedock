import CoreGraphics
import Testing

@testable import DisplayKit

private func mode(
    _ id: Int32, _ width: Int, _ height: Int, scale: Int = 1, hz: Double = 60,
    usable: Bool = true, native: Bool = false
) -> DisplayMode {
    DisplayMode(
        id: id, width: width, height: height, pixelWidth: width * scale, pixelHeight: height * scale,
        refreshRate: hz, isUsableForDesktop: usable, isNative: native)
}

struct ModeCatalogTests {
    private let modes = [
        mode(1, 1920, 1080, scale: 2, hz: 60, native: true),
        mode(2, 1920, 1080, hz: 144),
        mode(3, 1920, 1080, hz: 60),
        mode(4, 1280, 720, scale: 2, hz: 144),
        mode(5, 1280, 720, scale: 2, hz: 60),
        mode(6, 1280, 720, hz: 60),
        mode(7, 1024, 768, hz: 60),
        mode(8, 2560, 1440, hz: 60, usable: false),
    ]

    @Test func defaultListPrefersHiDPIAndNativeAspect() {
        let options = ModeCatalog.options(from: modes, showAll: false)
        // 1280x720 at 1x is a duplicate of the HiDPI one; 1920x1080 at 1x adds 144 Hz, so it stays.
        #expect(options.map(\.id) == ["1920x1080@2x", "1920x1080", "1280x720@2x"])
        #expect(options[0].isNative)
    }

    @Test func groupsRefreshRatesHighestFirst() {
        let options = ModeCatalog.options(from: modes, showAll: false)
        #expect(options[1].modes.map(\.refreshRate) == [144, 60])
    }

    @Test func showAllKeepsEverything() {
        let options = ModeCatalog.options(from: modes, showAll: true)
        #expect(
            options.map(\.id) == [
                "2560x1440", "1920x1080@2x", "1920x1080", "1280x720@2x", "1280x720", "1024x768",
            ])
        #expect(options.first { $0.id == "1920x1080" }?.modes.map(\.refreshRate) == [144, 60])
    }

    @Test func duplicateRefreshRatesCollapseToOne() {
        let options = ModeCatalog.options(
            from: [mode(1, 1920, 1080, hz: 60), mode(2, 1920, 1080, hz: 59.94), mode(3, 1920, 1080, hz: 60)],
            showAll: true)
        #expect(options.first?.modes.count == 1)
    }

    @Test func modeKeyIsStableAcrossIDs() {
        #expect(mode(1, 1920, 1080, scale: 2).key == mode(99, 1920, 1080, scale: 2).key)
        #expect(mode(1, 1920, 1080, scale: 2).key != mode(1, 1920, 1080).key)
    }
}

struct DisplayArrangementTests {
    @Test func makingMainShiftsAllDisplays() {
        let shifted = DisplayArrangement.origins(
            makingMain: 1, from: [5: .zero, 1: CGPoint(x: -1512, y: 98)])
        #expect(shifted?[1] == .zero)
        #expect(shifted?[5] == CGPoint(x: 1512, y: -98))
    }

    @Test func unknownDisplayReturnsNil() {
        #expect(DisplayArrangement.origins(makingMain: 9, from: [5: .zero]) == nil)
    }
}
