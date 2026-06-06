import CoreGraphics
import Darwin
import IOKit

/// Private macOS symbols, resolved at runtime so a missing one disables a single feature
/// instead of failing to launch.
public enum PrivateAPI {
    public typealias ConfigureDisplayEnabled =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    public typealias AVServiceCreateWithService =
        @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    public typealias AVServiceI2C =
        @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    public static let configureDisplayEnabled: ConfigureDisplayEnabled? =
        symbol("SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled")
    public static let avServiceCreateWithService: AVServiceCreateWithService? =
        symbol("IOAVServiceCreateWithService")
    public static let avServiceWriteI2C: AVServiceI2C? = symbol("IOAVServiceWriteI2C")
    public static let avServiceReadI2C: AVServiceI2C? = symbol("IOAVServiceReadI2C")

    nonisolated(unsafe) private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
        UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
    ]

    private static func symbol<T>(_ names: String...) -> T? {
        for name in names {
            for case let handle? in handles {
                if let pointer = dlsym(handle, name) {
                    return unsafeBitCast(pointer, to: T.self)
                }
            }
        }
        return nil
    }
}
