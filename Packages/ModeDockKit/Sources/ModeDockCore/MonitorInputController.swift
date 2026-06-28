import CoreGraphics
import DisplayKit
import Observation

/// Switches external monitors between their inputs over DDC (VCP 0x60).
@MainActor
@Observable
public final class MonitorInputController {
    public struct Inputs: Equatable, Sendable {
        /// The input the monitor shows now. DDC only works over that input, so it's this Mac's.
        public var current: UInt8
        /// From the monitor's capabilities string, or common inputs when it doesn't list any.
        public var available: [UInt8]
    }

    /// DisplayPort 1, HDMI 1 and HDMI 2: offered when a monitor doesn't list its inputs.
    public static let commonInputs: [UInt8] = [0x0F, 0x11, 0x12]

    public private(set) var screens: [CGDirectDisplayID: Inputs] = [:]
    public private(set) var lastError: String?

    private let ddc: DDCControlling
    private var identities: [CGDirectDisplayID: DisplayIdentity] = [:]
    /// Reading capabilities takes most of a second, and they don't change.
    private var listed: [DisplayIdentity: [UInt8]] = [:]

    public init(ddc: DDCControlling) {
        self.ddc = ddc
    }

    /// Reads the current input of every external screen that's on and answers over DDC.
    public func refresh(displays: [Display]) async {
        var updated: [CGDirectDisplayID: Inputs] = [:]
        for display in displays where display.isEnabled && !display.isBuiltin {
            identities[display.id] = display.identity
            guard let reply = try? await ddc.read(DDCPacket.VCP.inputSource, from: display.identity) else { continue }
            // Some monitors set flags in the high byte; the input is the low byte.
            let current = UInt8(reply.current & 0xFF)
            if listed[display.identity] == nil {
                let capabilities = (try? await ddc.capabilities(of: display.identity)) ?? ""
                listed[display.identity] = DDCPacket.inputSources(inCapabilities: capabilities)
            }
            var available = listed[display.identity] ?? []
            if available.isEmpty { available = Self.commonInputs }
            if !available.contains(current) { available.insert(current, at: 0) }
            updated[display.id] = Inputs(current: current, available: available)
        }
        screens = updated
    }

    public func select(_ input: UInt8, for display: CGDirectDisplayID) async {
        guard let identity = identities[display], screens[display]?.current != input else { return }
        lastError = await errorMessage {
            try await ddc.write(DDCPacket.VCP.inputSource, value: UInt16(input), to: identity)
        }
        if lastError == nil { screens[display]?.current = input }
    }
}
