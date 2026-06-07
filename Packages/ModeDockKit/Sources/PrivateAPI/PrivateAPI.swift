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

    public typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    public typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    public typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Built-in and Apple displays (Studio Display, Pro Display XDR).
    public static let canChangeBrightness: CanChangeBrightness? = symbol("DisplayServicesCanChangeBrightness")
    public static let getBrightness: GetBrightness? = symbol("DisplayServicesGetBrightness")
    public static let setBrightness: SetBrightness? = symbol("DisplayServicesSetBrightness")

    public typealias GetFlag = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    public typealias SetFlag = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    /// Automatic brightness ("ambient light compensation"), for displays with a light sensor.
    public static let hasAutoBrightness: CanChangeBrightness? = symbol("DisplayServicesHasAmbientLightCompensation")
    public static let autoBrightnessEnabled: GetFlag? = symbol("DisplayServicesAmbientLightCompensationEnabled")
    public static let setAutoBrightness: SetFlag? = symbol("DisplayServicesEnableAmbientLightCompensation")

    public typealias LockScreen = @convention(c) () -> Int32

    /// Locks the screen right away, like Control-Command-Q.
    public static let lockScreen: LockScreen? = symbol("SACLockScreenImmediate")

    nonisolated(unsafe) private static let handles: [UnsafeMutableRawPointer?] = [
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
        dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
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
