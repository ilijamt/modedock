import Foundation
import Observation
import ServiceManagement

public protocol LoginItemService: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: @retroactive @unchecked Sendable {}
extension SMAppService: LoginItemService {}

@MainActor
@Observable
public final class LaunchAtLogin {
    public private(set) var isEnabled: Bool
    public private(set) var lastError: String?

    private let service: LoginItemService

    public init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
        self.isEnabled = service.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isEnabled = service.status == .enabled
    }

    /// The user can remove the login item in System Settings while ModeDock runs.
    public func refresh() {
        isEnabled = service.status == .enabled
    }
}
