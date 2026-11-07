import CoreGraphics
import Foundation
import Testing

@testable import ModeDockCore

@MainActor
private final class FakeScreenshotSystem: ScreenshotSystem {
    var permission = true
    var permissionRequests = 0
    var displays: [CGDirectDisplayID] = [5, 1]
    var files: Set<String> = []
    var copied: [[URL]] = []
    var arrangements: [[CGRect]?] = []
    var copySucceeds = true
    var runs: [[String]] = []
    var behaviour: Behaviour = .succeed
    var status: Int32 = 0

    enum Behaviour { case succeed, cancel }

    func hasPermission() -> Bool { permission }
    func requestPermission() { permissionRequests += 1 }

    func capture(arguments: [String]) async throws -> Int32 {
        runs.append(arguments)
        guard behaviour == .succeed else { return 1 }
        files.formUnion(arguments.filter { $0.hasPrefix("/") })
        return status
    }

    func fileExists(_ url: URL) -> Bool { files.contains(url.path) }
    func removeFile(_ url: URL) { files.remove(url.path) }
    func temporaryFolder() -> URL { URL(fileURLWithPath: "/tmp/modedock") }

    func copyImages(_ files: [URL], arrangedIn bounds: [CGRect]?, hdr: Bool) -> Bool {
        copied.append(files)
        arrangements.append(bounds)
        return copySucceeds
    }

    var combined: [URL] = []

    func combineImages(
        _ files: [URL], arrangedIn bounds: [CGRect], into file: URL, format: ScreenshotFormat, hdr: Bool
    ) -> Bool {
        combined.append(file)
        self.files.insert(file.path)
        return true
    }

    func bounds(of display: CGDirectDisplayID) -> CGRect {
        display == 5 ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : CGRect(x: -1512, y: 98, width: 1512, height: 982)
    }
    func activeDisplays() -> [CGDirectDisplayID] { displays }
    func defaultFolder() -> URL { URL(fileURLWithPath: "/Users/me/Desktop") }
}

@MainActor
struct ScreenshotControllerTests {
    private let folder = URL(fileURLWithPath: "/tmp/shots")
    private var date: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 1, minute: 23, second: 45))!
    }

    private func options(_ destination: ScreenshotDestination? = nil) -> ScreenshotOptions {
        ScreenshotOptions(destination: destination ?? .folder(folder))
    }

    @Test func buildsArgumentsForEachMode() {
        let file = [URL(fileURLWithPath: "/tmp/a.png")]
        let defaults = options()
        #expect(
            ScreenshotController.arguments(mode: .area, options: defaults, displayIndex: nil, files: file)
                == ["-i", "-s", "-t", "png", "/tmp/a.png"])
        #expect(
            ScreenshotController.arguments(mode: .window, options: defaults, displayIndex: nil, files: file)
                == ["-i", "-w", "-t", "png", "/tmp/a.png"])
        #expect(
            ScreenshotController.arguments(mode: .screen, options: defaults, displayIndex: 2, files: file)
                == ["-D", "2", "-t", "png", "/tmp/a.png"])
        let two = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")]
        #expect(
            ScreenshotController.arguments(mode: .allScreens, options: defaults, displayIndex: 2, files: two)
                == ["-t", "png", "/tmp/a.png", "/tmp/b.png"])
    }

    @Test func buildsArgumentsForOptions() {
        let options = ScreenshotOptions(
            destination: .clipboard, format: .jpg, includePointer: true, playSound: false, windowShadow: false,
            delay: 5)
        #expect(
            ScreenshotController.arguments(mode: .screen, options: options, displayIndex: 1, files: [])
                == ["-x", "-D", "1", "-C", "-T", "5", "-t", "jpg"])
        // The pointer and timer only apply to screen captures; the shadow only to windows.
        #expect(
            ScreenshotController.arguments(mode: .window, options: options, displayIndex: nil, files: [])
                == ["-x", "-i", "-w", "-o", "-t", "jpg"])
        #expect(
            ScreenshotController.arguments(mode: .area, options: options, displayIndex: nil, files: [])
                == ["-x", "-i", "-s", "-t", "jpg"])
    }

    @Test func capturesHDRWhenAsked() {
        var options = options()
        options.hdr = true
        #expect(
            ScreenshotController.arguments(mode: .area, options: options, displayIndex: nil, files: [])
                == ["-i", "-s", "-H", "-t", "heic"])
    }

    @Test func savesToATimestampedFile() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        let result = await controller.capture(.area, options: options(), date: date)
        let expected = URL(fileURLWithPath: "/tmp/shots/ModeDock 2026-11-15 at 01.23.45.png")
        #expect(result == .saved([expected]))
        #expect(controller.lastSaved == [expected])
        #expect(controller.lastError == nil)
    }

    @Test func neverOverwritesAnExistingFile() {
        let system = FakeScreenshotSystem()
        system.files = ["/tmp/shots/ModeDock 2026-11-15 at 01.23.45.png"]
        let controller = ScreenshotController(system: system)
        var heic = options()
        heic.format = .heic
        #expect(
            controller.fileURLs(in: folder, count: 1, options: options(), date: date).map(\.lastPathComponent)
                == ["ModeDock 2026-11-15 at 01.23.45 2.png"])
        #expect(
            controller.fileURLs(in: folder, count: 1, options: heic, date: date).map(\.lastPathComponent)
                == ["ModeDock 2026-11-15 at 01.23.45.heic"])
    }

    @Test func capturesTheScreenUnderTheMouseByItsIndex() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        await controller.capture(.screen, display: 1, options: options(), date: date)
        #expect(system.runs.last?.prefix(2) == ["-D", "2"])
        await controller.capture(.screen, display: 99, options: options(), date: date)
        #expect(system.runs.last?.contains("-D") == false)
    }

    @Test func savesOneFilePerScreen() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        let result = await controller.capture(.allScreens, options: options(), date: date)
        #expect(
            result
                == .saved([
                    folder.appendingPathComponent("ModeDock 2026-11-15 at 01.23.45 (1).png"),
                    folder.appendingPathComponent("ModeDock 2026-11-15 at 01.23.45 (2).png"),
                ]))
    }

    @Test func copiesToTheClipboardWithoutKeepingFiles() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.window, options: options(.clipboard), date: date) == .copied)
        let temporary = URL(fileURLWithPath: "/tmp/modedock/ModeDock 2026-11-15 at 01.23.45.png")
        #expect(system.copied == [[temporary]])
        #expect(system.arrangements == [nil])
        #expect(system.files.isEmpty)
        #expect(controller.lastSaved.isEmpty)
    }

    @Test func allScreensCanBeCopied() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.allScreens, options: options(.clipboard), date: date) == .copied)
        #expect(system.copied.first?.count == 2)
        #expect(
            system.arrangements.first
                == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1512, y: 98, width: 1512, height: 982)])
    }

    @Test func combinesAllScreensIntoOneFile() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        var combined = options()
        combined.combinesScreens = true
        let expected = folder.appendingPathComponent("ModeDock 2026-11-15 at 01.23.45.png")

        #expect(await controller.capture(.allScreens, options: combined, date: date) == .saved([expected]))
        #expect(system.combined == [expected])
        #expect(system.files == [expected.path])
    }

    @Test func processesCapturesBeforeCopying() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        var processed: [(ScreenshotMode, [URL])] = []
        controller.processCaptures = { processed.append(($0, $1)) }

        await controller.capture(.area, options: options(.clipboard), date: date)

        #expect(processed.map(\.0) == [.area])
        #expect(processed.first?.1 == system.copied.first)
    }

    @Test func arrangesScreensLikeTheDisplays() {
        let layout = ScreenshotController.arrangement(
            of: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1512, y: 98, width: 1512, height: 982)],
            scale: 2)
        #expect(layout.size == CGSize(width: 6864, height: 2160))
        // Bottom-left origin: the main screen is at the top right, the laptop at the bottom left.
        #expect(layout.frames[0] == CGRect(x: 3024, y: 0, width: 3840, height: 2160))
        #expect(layout.frames[1] == CGRect(x: 0, y: 0, width: 3024, height: 1964))
    }

    @Test func savesAndCopies() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        let both = ScreenshotDestination(folder: folder, copiesToClipboard: true)
        let expected = URL(fileURLWithPath: "/tmp/shots/ModeDock 2026-11-15 at 01.23.45.png")
        #expect(await controller.capture(.area, options: options(both), date: date) == .saved([expected]))
        #expect(system.copied == [[expected]])
        #expect(system.files.contains(expected.path))
    }

    @Test func aFailedCopyIsAnError() async {
        let system = FakeScreenshotSystem()
        system.copySucceeds = false
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.screen, options: options(.clipboard), date: date) == .failed)
        #expect(controller.lastError != nil)
        #expect(system.files.isEmpty)
    }

    @Test func cancelledCapturesAreNotErrors() async {
        let system = FakeScreenshotSystem()
        system.behaviour = .cancel
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.area, options: options(), date: date) == .cancelled)
        #expect(await controller.capture(.window, options: options(.clipboard)) == .cancelled)
        #expect(controller.lastError == nil)

        #expect(await controller.capture(.screen, options: options(), date: date) == .failed)
        #expect(controller.lastError != nil)
    }

    @Test func waitsForPermission() async {
        let system = FakeScreenshotSystem()
        system.permission = false
        let controller = ScreenshotController(system: system)
        #expect(!controller.hasPermission)
        #expect(await controller.capture(.area, options: options()) == .needsPermission)
        #expect(system.runs.isEmpty)

        controller.requestPermission()
        #expect(system.permissionRequests == 1)
        system.permission = true
        #expect(await controller.capture(.area, options: options(), date: date) != .needsPermission)
        #expect(controller.hasPermission)
    }
}
