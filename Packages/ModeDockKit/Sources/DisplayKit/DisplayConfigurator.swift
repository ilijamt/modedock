import CoreGraphics
import Foundation

/// Display modes, arrangement and mirroring. Abstracted so the controller can be tested without
/// real displays.
@MainActor
public protocol DisplayConfiguring {
    func modes(for display: CGDirectDisplayID, includeDuplicates: Bool) -> [DisplayMode]
    func currentMode(for display: CGDirectDisplayID) -> DisplayMode?
    func setMode(_ mode: DisplayMode, for display: CGDirectDisplayID) throws
    func origins(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGPoint]
    func setOrigins(_ origins: [CGDirectDisplayID: CGPoint]) throws
    /// The display each display mirrors, for displays that mirror another.
    func mirrors(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGDirectDisplayID]
    /// Mirrors `displays` onto `source`, or stops mirroring them when `source` is nil.
    func setMirroring(_ displays: [CGDirectDisplayID], to source: CGDirectDisplayID?) throws
}

/// Applies one change as a CoreGraphics configuration transaction, cancelled when the change fails.
func configureDisplays(_ option: CGConfigureOption, _ change: (CGDisplayConfigRef?) -> CGError) throws {
    var config: CGDisplayConfigRef?
    var result = CGBeginDisplayConfiguration(&config)
    guard result == .success else { throw DisplayError.coreGraphics(result.rawValue) }
    result = change(config)
    guard result == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayError.coreGraphics(result.rawValue)
    }
    result = CGCompleteDisplayConfiguration(config, option)
    guard result == .success else { throw DisplayError.coreGraphics(result.rawValue) }
}

@MainActor
public struct CoreGraphicsDisplayConfigurator: DisplayConfiguring {
    public init() {}

    public func modes(for display: CGDirectDisplayID, includeDuplicates: Bool) -> [DisplayMode] {
        cgModes(for: display, includeDuplicates: includeDuplicates).map(Self.mode)
    }

    public func currentMode(for display: CGDirectDisplayID) -> DisplayMode? {
        CGDisplayCopyDisplayMode(display).map(Self.mode)
    }

    public func setMode(_ mode: DisplayMode, for display: CGDirectDisplayID) throws {
        guard
            let cgMode = cgModes(for: display, includeDuplicates: true).first(where: { $0.ioDisplayModeID == mode.id })
        else { throw DisplayError.modeUnavailable }
        try configure { config in
            CGConfigureDisplayWithDisplayMode(config, display, cgMode, nil)
        }
    }

    public func origins(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGPoint] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0, CGDisplayBounds($0).origin) })
    }

    public func setOrigins(_ origins: [CGDirectDisplayID: CGPoint]) throws {
        try configure { config in
            for (display, origin) in origins {
                let result = CGConfigureDisplayOrigin(config, display, Int32(origin.x), Int32(origin.y))
                if result != .success { return result }
            }
            return .success
        }
    }

    public func mirrors(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: CGDirectDisplayID] {
        displays.reduce(into: [:]) { result, display in
            let source = CGDisplayMirrorsDisplay(display)
            if source != kCGNullDirectDisplay { result[display] = source }
        }
    }

    public func setMirroring(_ displays: [CGDirectDisplayID], to source: CGDirectDisplayID?) throws {
        try configure { config in
            for display in displays where display != source {
                let result = CGConfigureDisplayMirrorOfDisplay(config, display, source ?? kCGNullDirectDisplay)
                if result != .success { return result }
            }
            return .success
        }
    }

    private func cgModes(for display: CGDirectDisplayID, includeDuplicates: Bool) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: includeDuplicates] as CFDictionary
        return CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []
    }

    /// `.permanently` makes the change survive logout, the same as System Settings.
    private func configure(_ change: (CGDisplayConfigRef?) -> CGError) throws {
        try configureDisplays(.permanently, change)
    }

    private static let nativeFlag: UInt32 = 0x0200_0000  // kDisplayModeNativeFlag
    private static let defaultFlag: UInt32 = 0x0000_0004  // kDisplayModeDefaultFlag

    private static func mode(_ cgMode: CGDisplayMode) -> DisplayMode {
        DisplayMode(
            id: cgMode.ioDisplayModeID,
            width: cgMode.width,
            height: cgMode.height,
            pixelWidth: cgMode.pixelWidth,
            pixelHeight: cgMode.pixelHeight,
            refreshRate: cgMode.refreshRate,
            isUsableForDesktop: cgMode.isUsableForDesktopGUI(),
            isNative: cgMode.ioFlags & nativeFlag != 0,
            isDefault: cgMode.ioFlags & defaultFlag != 0
        )
    }
}
