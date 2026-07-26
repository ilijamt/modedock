import AppKit
import Foundation
import Observation
import PrivateAPI

/// The current state of the system toggles. nil means this Mac doesn't support that toggle.
public struct UtilityState: Equatable, Sendable {
    public var darkMode: Bool?
    public var dockAutoHide: Bool?
    public var desktopIcons = true
    public var hiddenFiles = false
    public var nightShift: Bool?
    public var trueTone: Bool?
    /// External and removable volumes that Eject All would eject.
    public var ejectableVolumes = 0

    public init(
        darkMode: Bool? = nil, dockAutoHide: Bool? = nil, desktopIcons: Bool = true, hiddenFiles: Bool = false,
        nightShift: Bool? = nil, trueTone: Bool? = nil, ejectableVolumes: Int = 0
    ) {
        self.darkMode = darkMode
        self.dockAutoHide = dockAutoHide
        self.desktopIcons = desktopIcons
        self.hiddenFiles = hiddenFiles
        self.nightShift = nightShift
        self.trueTone = trueTone
        self.ejectableVolumes = ejectableVolumes
    }
}

public enum UtilityError: Error, LocalizedError {
    case unsupported
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This isn't supported on this Mac.", bundle: .module)
        case .failed(let message): message
        }
    }
}

/// The system calls behind the utilities, abstracted for tests.
@MainActor
public protocol UtilitySystem {
    func state() -> UtilityState
    func setDarkMode(_ on: Bool) throws
    func setDockAutoHide(_ on: Bool) throws
    func setDesktopIcons(_ shown: Bool) throws
    func setHiddenFiles(_ shown: Bool) throws
    func setNightShift(_ on: Bool) throws
    func setTrueTone(_ on: Bool) throws
    func emptyTrash() throws
    func ejectableVolumes() -> [URL]
    func eject(_ volume: URL) async throws
}

@MainActor
@Observable
public final class UtilitiesController {
    public private(set) var state = UtilityState()
    public private(set) var lastError: String?
    public private(set) var isEjecting = false

    private let system: UtilitySystem

    public init(system: UtilitySystem = MacUtilitySystem()) {
        self.system = system
    }

    public func refresh() {
        state = system.state()
    }

    public func setDarkMode(_ on: Bool) { apply { try system.setDarkMode(on) } }
    public func setDockAutoHide(_ on: Bool) { apply { try system.setDockAutoHide(on) } }
    public func setDesktopIcons(_ shown: Bool) { apply { try system.setDesktopIcons(shown) } }
    public func setHiddenFiles(_ shown: Bool) { apply { try system.setHiddenFiles(shown) } }
    public func setNightShift(_ on: Bool) { apply { try system.setNightShift(on) } }
    public func setTrueTone(_ on: Bool) { apply { try system.setTrueTone(on) } }
    public func emptyTrash() { apply { try system.emptyTrash() } }

    /// Turns one of the settings a profile can set on or off.
    public func set(_ setting: ProfileSystemSettings.Setting, to on: Bool) {
        switch setting {
        case .darkMode: setDarkMode(on)
        case .nightShift: setNightShift(on)
        case .trueTone: setTrueTone(on)
        case .dockAutoHide: setDockAutoHide(on)
        }
    }

    /// Ejects every external and removable volume, and reports the ones that refused (for
    /// example because a file on them is open).
    public func ejectAll() async {
        guard !isEjecting else { return }
        isEjecting = true
        defer {
            isEjecting = false
            refresh()
        }
        var failed: [String] = []
        for volume in system.ejectableVolumes() {
            do {
                try await system.eject(volume)
            } catch {
                failed.append(volume.lastPathComponent)
            }
        }
        lastError =
            failed.isEmpty
            ? nil
            : String(localized: "Couldn't eject \(failed.joined(separator: ", ")). It may be in use.", bundle: .module)
    }

    private func apply(_ change: () throws -> Void) {
        lastError = errorMessage(change)
        refresh()
    }
}

/// The real implementation: private SkyLight, Dock and CoreBrightness calls where they avoid
/// permission prompts, Finder preferences, and Finder's AppleScript for emptying the Trash.
@MainActor
public struct MacUtilitySystem: UtilitySystem {
    private static let finder = "com.apple.finder" as CFString

    public init() {}

    public func state() -> UtilityState {
        UtilityState(
            darkMode: PrivateAPI.darkMode?(),
            dockAutoHide: PrivateAPI.dockAutoHide?(),
            desktopIcons: Self.finderFlag("CreateDesktop") ?? true,
            hiddenFiles: Self.finderFlag("AppleShowAllFiles") ?? false,
            nightShift: CoreBrightness.nightShift(),
            trueTone: CoreBrightness.trueTone(),
            ejectableVolumes: ejectableVolumes().count
        )
    }

    public func setDarkMode(_ on: Bool) throws {
        guard let set = PrivateAPI.setDarkMode else { throw UtilityError.unsupported }
        set(on)
    }

    public func setDockAutoHide(_ on: Bool) throws {
        guard let set = PrivateAPI.setDockAutoHide else { throw UtilityError.unsupported }
        set(on)
    }

    public func setDesktopIcons(_ shown: Bool) throws {
        try Self.setFinderFlag("CreateDesktop", shown)
    }

    public func setHiddenFiles(_ shown: Bool) throws {
        try Self.setFinderFlag("AppleShowAllFiles", shown)
    }

    public func setNightShift(_ on: Bool) throws {
        guard CoreBrightness.setNightShift(on) else {
            throw UtilityError.failed(String(localized: "Night Shift couldn't be changed.", bundle: .module))
        }
    }

    public func setTrueTone(_ on: Bool) throws {
        guard CoreBrightness.setTrueTone(on) else {
            throw UtilityError.failed(String(localized: "True Tone couldn't be changed.", bundle: .module))
        }
    }

    /// macOS has no API for this; asking Finder empties the Trash on every volume, and asks the
    /// user once to let ModeDock control Finder. Finder reports an error when the Trash is
    /// already empty, so that case is skipped.
    public func emptyTrash() throws {
        var error: NSDictionary?
        NSAppleScript(
            source: "tell application \"Finder\" to if (count items of trash) > 0 then empty trash"
        )?.executeAndReturnError(&error)
        guard let error else { return }
        if error[NSAppleScript.errorNumber] as? Int == -1743 {
            throw UtilityError.failed(
                String(
                    localized:
                        "ModeDock isn't allowed to control Finder. Allow it in System Settings → Privacy & Security → Automation.",
                    bundle: .module)
            )
        }
        throw UtilityError.failed(
            error[NSAppleScript.errorMessage] as? String
                ?? String(localized: "The Trash couldn't be emptied.", bundle: .module))
    }

    public func ejectableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey,
            .volumeIsRootFileSystemKey,
        ]
        let volumes =
            FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
            ?? []
        return volumes.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            guard values.volumeIsRootFileSystem != true, values.volumeIsLocal != false else { return false }
            return values.volumeIsEjectable == true || values.volumeIsRemovable == true
                || values.volumeIsInternal == false
        }
    }

    public func eject(_ volume: URL) async throws {
        // Unmounting blocks until the disk lets go, so it runs off the main thread.
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) }.value
    }

    private static func finderFlag(_ key: String) -> Bool? {
        CFPreferencesCopyAppValue(key as CFString, finder) as? Bool
    }

    /// Finder only reads these settings at launch, so it's restarted; it comes back on its own.
    private static func setFinderFlag(_ key: String, _ value: Bool) throws {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, finder)
        guard CFPreferencesAppSynchronize(finder) else {
            throw UtilityError.failed(String(localized: "Finder's settings couldn't be saved.", bundle: .module))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Finder"]
        try process.run()
        process.waitUntilExit()
    }
}
