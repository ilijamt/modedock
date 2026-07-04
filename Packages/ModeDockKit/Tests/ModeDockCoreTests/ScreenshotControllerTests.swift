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
    var changeCount = 0
    var runs: [[String]] = []
    /// What a capture does: write the files it was given, copy to the clipboard, or nothing (Esc).
    var behaviour: Behaviour = .succeed
    var status: Int32 = 0

    enum Behaviour { case succeed, cancel }

    func hasPermission() -> Bool { permission }
    func requestPermission() { permissionRequests += 1 }

    func capture(arguments: [String]) async throws -> Int32 {
        runs.append(arguments)
        guard behaviour == .succeed else { return 1 }
        if arguments.contains("-c") {
            changeCount += 1
        } else {
            files.formUnion(arguments.filter { $0.hasPrefix("/") })
        }
        return status
    }

    func fileExists(_ url: URL) -> Bool { files.contains(url.path) }
    func pasteboardChangeCount() -> Int { changeCount }
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
                == ["-x", "-D", "1", "-C", "-T", "5", "-c", "-t", "jpg"])
        // The pointer and timer only apply to screen captures; the shadow only to windows.
        #expect(
            ScreenshotController.arguments(mode: .window, options: options, displayIndex: nil, files: [])
                == ["-x", "-i", "-w", "-o", "-c", "-t", "jpg"])
        #expect(
            ScreenshotController.arguments(mode: .area, options: options, displayIndex: nil, files: [])
                == ["-x", "-i", "-s", "-c", "-t", "jpg"])
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

    @Test func allScreensNeedsAFolder() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.allScreens, options: options(.clipboard)) == .failed)
        #expect(system.runs.isEmpty)
        #expect(controller.lastError != nil)
    }

    @Test func copiesToTheClipboard() async {
        let system = FakeScreenshotSystem()
        let controller = ScreenshotController(system: system)
        #expect(await controller.capture(.window, options: options(.clipboard)) == .copied)
        #expect(system.runs.last?.contains("-c") == true)
        #expect(controller.lastSaved.isEmpty)
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
