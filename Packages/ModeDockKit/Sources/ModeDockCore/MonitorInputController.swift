import CoreGraphics
import DisplayKit
import Observation

@MainActor
@Observable
public final class MonitorInputController {
    public struct Inputs: Equatable, Sendable {
        /// DDC only works over the active input, so it's this Mac's.
        public var current: UInt8
        public var available: [UInt8]
    }

    /// Offered when a monitor doesn't list its inputs.
    public static let commonInputs: [UInt8] = [0x0F, 0x11, 0x12]

    public private(set) var screens: [CGDirectDisplayID: Inputs] = [:]
    public private(set) var lastError: String? {
        // Only the error kind is counted, never its text.
        didSet { if lastError != nil, lastError != oldValue { Telemetry.shared.record(.errorInput) } }
    }

    private let ddc: DDCControlling
    private var identities: [CGDirectDisplayID: DisplayIdentity] = [:]
    /// Reading capabilities takes most of a second, and they don't change.
    private var listed: [DisplayIdentity: [UInt8]] = [:]
    private var failedReads: [DisplayIdentity: Int] = [:]
    /// Refreshes run on every panel open, and a failed read holds up DDC brightness meanwhile.
    static let capabilityAttempts = 3

    public init(ddc: DDCControlling) {
        self.ddc = ddc
    }

    public func refresh(displays: [Display]) async {
        var updated: [CGDirectDisplayID: Inputs] = [:]
        for display in displays where display.isEnabled && !display.isBuiltin {
            identities[display.id] = display.identity
            guard let reply = try? await ddc.read(DDCPacket.VCP.inputSource, from: display.identity) else { continue }
            // Some monitors set flags in the high byte; the input is the low byte.
            let current = UInt8(reply.current & 0xFF)
            if listed[display.identity] == nil {
                if let capabilities = try? await ddc.capabilities(of: display.identity) {
                    listed[display.identity] = DDCPacket.inputSources(inCapabilities: capabilities)
                } else {
                    // Tried again on the next few refreshes, then it keeps the common inputs.
                    failedReads[display.identity, default: 0] += 1
                    if failedReads[display.identity, default: 0] >= Self.capabilityAttempts {
                        listed[display.identity] = []
                    }
                }
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
        Telemetry.shared.record(.screenInput)
        lastError = await errorMessage {
            try await ddc.write(DDCPacket.VCP.inputSource, value: UInt16(input), to: identity)
        }
        if lastError == nil { screens[display]?.current = input }
    }
}
