import Foundation

public enum CoreBrightness {
    private typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

    private static let loaded: Bool =
        Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() ?? false

    nonisolated(unsafe) private static let blueLightClient = client("CBBlueLightClient")
    nonisolated(unsafe) private static let trueToneClient = client("CBTrueToneClient")

    public static func nightShift() -> Bool? {
        guard let blueLight = blueLightClient, let get: GetStatus = method(blueLight, "getBlueLightStatus:") else {
            return nil
        }
        // The C struct is { BOOL active, enabled, sunSchedulePermitted; int mode; 4 x int schedule;
        // uint64 disableFlags; BOOL available }, 40 bytes with padding. A larger buffer is used so a
        // longer struct in a future macOS can't write past it.
        var buffer = [UInt8](repeating: 0, count: 128)
        let ok = buffer.withUnsafeMutableBytes { raw in
            raw.baseAddress.map { get(blueLight, NSSelectorFromString("getBlueLightStatus:"), $0) } ?? false
        }
        guard ok, buffer[32] != 0 else { return nil }
        return buffer[1] != 0
    }

    public static func setNightShift(_ enabled: Bool) -> Bool {
        guard let blueLight = blueLightClient, let set: SetBool = method(blueLight, "setEnabled:") else { return false }
        return set(blueLight, NSSelectorFromString("setEnabled:"), enabled)
    }

    public static func trueTone() -> Bool? {
        guard let trueTone = trueToneClient, let get: GetBool = method(trueTone, "supported"),
            get(trueTone, NSSelectorFromString("supported")),
            let available: GetBool = method(trueTone, "available"),
            available(trueTone, NSSelectorFromString("available")),
            let enabled: GetBool = method(trueTone, "enabled")
        else { return nil }
        return enabled(trueTone, NSSelectorFromString("enabled"))
    }

    public static func setTrueTone(_ enabled: Bool) -> Bool {
        guard let trueTone = trueToneClient, let set: SetBool = method(trueTone, "setEnabled:") else { return false }
        return set(trueTone, NSSelectorFromString("setEnabled:"), enabled)
    }

    private static func client(_ name: String) -> NSObject? {
        guard loaded, let type = NSClassFromString(name) as? NSObject.Type else { return nil }
        return type.init()
    }

    private static func method<T>(_ object: NSObject, _ name: String) -> T? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return unsafeBitCast(object.method(for: selector), to: T.self)
    }
}
