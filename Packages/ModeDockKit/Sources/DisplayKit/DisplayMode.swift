import CoreGraphics
import Foundation

public struct DisplayMode: Identifiable, Hashable, Sendable {
    /// `CGDisplayModeGetIODisplayModeID`; unique per display.
    public let id: Int32
    /// Size in points ("looks like").
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// 0 for displays that don't report one (some built-in panels).
    public let refreshRate: Double
    public let isUsableForDesktop: Bool
    public let isNative: Bool

    public var isHiDPI: Bool { pixelWidth > width }

    /// Identifies the same mode across reconnects, where `id` may change.
    public var key: String {
        "\(width)x\(height)\(isHiDPI ? "@2x" : "")@\(Int(refreshRate.rounded()))"
    }

    public init(
        id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
        refreshRate: Double, isUsableForDesktop: Bool = true, isNative: Bool = false
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsableForDesktop = isUsableForDesktop
        self.isNative = isNative
    }
}

/// One entry in the resolution menu: a size, with one mode per refresh rate.
public struct ResolutionOption: Identifiable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let isHiDPI: Bool
    public let isNative: Bool
    /// Highest refresh rate first.
    public let modes: [DisplayMode]

    public var id: String { "\(width)x\(height)\(isHiDPI ? "@2x" : "")" }

    var refreshRates: Set<Int> { Set(modes.map { Int($0.refreshRate.rounded()) }) }
}

public enum ModeCatalog {
    /// Groups modes into menu entries, largest first. Unless `showAll` is set, it keeps the list
    /// close to System Settings: modes usable for the desktop, in the native aspect ratio, and
    /// only the HiDPI version of a size when one exists.
    public static func options(from modes: [DisplayMode], showAll: Bool) -> [ResolutionOption] {
        var candidates = modes
        if !showAll {
            candidates = candidates.filter(\.isUsableForDesktop)
            if let native = modes.first(where: \.isNative) ?? modes.max(by: { $0.pixelWidth < $1.pixelWidth }) {
                let aspect = Double(native.pixelWidth) / Double(native.pixelHeight)
                candidates = candidates.filter { abs(Double($0.width) / Double($0.height) - aspect) < 0.02 }
            }
        }

        let groups = Dictionary(grouping: candidates) {
            GroupKey(width: $0.width, height: $0.height, hiDPI: $0.isHiDPI)
        }
        var options = groups.map { key, modes in
            ResolutionOption(
                width: key.width,
                height: key.height,
                isHiDPI: key.hiDPI,
                isNative: modes.contains(where: \.isNative),
                modes: uniqueByRefreshRate(modes)
            )
        }

        if !showAll {
            // A standard-resolution size is a blurry duplicate of its HiDPI version, unless it
            // offers refresh rates the HiDPI one can't (e.g. 144 Hz at 1920x1080).
            let hiDPIRates = Dictionary(
                options.filter(\.isHiDPI).map { (Size(width: $0.width, height: $0.height), $0.refreshRates) },
                uniquingKeysWith: { first, _ in first })
            options.removeAll { option in
                guard !option.isHiDPI, let rates = hiDPIRates[Size(width: option.width, height: option.height)]
                else { return false }
                return option.refreshRates.isSubset(of: rates)
            }
        }

        return options.sorted {
            ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0)
        }
    }

    private struct Size: Hashable {
        let width: Int
        let height: Int
    }

    private struct GroupKey: Hashable {
        let width: Int
        let height: Int
        let hiDPI: Bool
    }

    /// Several modes can share a size and refresh rate (different pixel encodings); keep one,
    /// preferring the native and then the largest backing size.
    private static func uniqueByRefreshRate(_ modes: [DisplayMode]) -> [DisplayMode] {
        let byRate = Dictionary(grouping: modes) { Int($0.refreshRate.rounded()) }
        return byRate.values
            .compactMap { group in
                group.max { ($0.isNative ? 1 : 0, $0.pixelWidth) < ($1.isNative ? 1 : 0, $1.pixelWidth) }
            }
            .sorted { $0.refreshRate > $1.refreshRate }
    }
}

public enum DisplayArrangement {
    /// macOS treats the display at the origin as the main one, so making a display main means
    /// shifting every display by the same offset.
    public static func origins(
        makingMain target: CGDirectDisplayID, from origins: [CGDirectDisplayID: CGPoint]
    ) -> [CGDirectDisplayID: CGPoint]? {
        guard let anchor = origins[target] else { return nil }
        return origins.mapValues { CGPoint(x: $0.x - anchor.x, y: $0.y - anchor.y) }
    }
}
