import ServiceManagement
import Testing

@testable import ModeDockCore

private final class FakeLoginItemService: LoginItemService, @unchecked Sendable {
    var status: SMAppService.Status = .notRegistered
    var failNext = false

    struct Failure: Error {}

    func register() throws {
        if failNext { throw Failure() }
        status = .enabled
    }

    func unregister() throws {
        if failNext { throw Failure() }
        status = .notRegistered
    }
}

@MainActor
struct LaunchAtLoginTests {
    @Test func reflectsInitialStatus() {
        let service = FakeLoginItemService()
        service.status = .enabled
        #expect(LaunchAtLogin(service: service).isEnabled)
    }

    @Test func enableAndDisable() {
        let service = FakeLoginItemService()
        let launch = LaunchAtLogin(service: service)

        launch.setEnabled(true)
        #expect(launch.isEnabled)

        launch.setEnabled(false)
        #expect(!launch.isEnabled)
        #expect(launch.lastError == nil)
    }

    @Test func failureKeepsActualStatusAndReportsError() {
        let service = FakeLoginItemService()
        service.failNext = true
        let launch = LaunchAtLogin(service: service)

        launch.setEnabled(true)
        #expect(!launch.isEnabled)
        #expect(launch.lastError != nil)
    }

    @Test func refreshPicksUpExternalChange() {
        let service = FakeLoginItemService()
        let launch = LaunchAtLogin(service: service)
        service.status = .enabled
        launch.refresh()
        #expect(launch.isEnabled)
    }
}
