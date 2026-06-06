import Foundation
import IOKit
import PrivateAPI

public enum DDCError: Error, Equatable, LocalizedError {
    case unavailable
    case io(Int32)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This monitor can't be controlled over DDC."
        case .io(let code): "The monitor didn't respond to DDC (error \(code))."
        case .badReply: "The monitor sent an invalid DDC reply."
        }
    }
}

public protocol DDCControlling: Sendable {
    /// Rescans the I/O Registry; call after displays are connected or disconnected.
    func refresh() async
    func read(_ code: UInt8, from display: DisplayIdentity) async throws -> DDCPacket.Reply
    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity) async throws
}

/// DDC over the Apple Silicon `IOAVService` I²C interface. Calls block for tens of
/// milliseconds, so they run on this actor rather than the main thread.
public actor DDCService: DDCControlling {
    private var services: [DisplayIdentity: CFTypeRef] = [:]

    public init() {}

    public func refresh() {
        services = Self.scanExternalServices()
    }

    public func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply {
        let service = try service(for: display)
        var lastError = DDCError.badReply
        for _ in 0..<3 {
            do {
                try send(DDCPacket.getVCP(code), to: service)
                usleep(40_000)
                var buffer = [UInt8](repeating: 0, count: 12)
                let result = buffer.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress, let readI2C = PrivateAPI.avServiceReadI2C else {
                        return kIOReturnUnsupported
                    }
                    return readI2C(service, DDCPacket.chipAddress, DDCPacket.hostAddress, base, UInt32(raw.count))
                }
                guard result == kIOReturnSuccess else { throw DDCError.io(result) }
                if let reply = DDCPacket.parseReply(buffer, code: code) { return reply }
                lastError = .badReply
            } catch let error as DDCError {
                lastError = error
            }
            usleep(20_000)
        }
        throw lastError
    }

    public func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity) throws {
        let service = try service(for: display)
        // Many monitors drop a single write; sending it twice is what other DDC tools do too.
        try send(DDCPacket.setVCP(code, value: value), to: service)
        usleep(20_000)
        try send(DDCPacket.setVCP(code, value: value), to: service)
    }

    private func service(for display: DisplayIdentity) throws -> CFTypeRef {
        if services.isEmpty { refresh() }
        guard let service = services[display] else { throw DDCError.unavailable }
        return service
    }

    private func send(_ packet: [UInt8], to service: CFTypeRef) throws {
        guard let write = PrivateAPI.avServiceWriteI2C else { throw DDCError.unavailable }
        var bytes = packet
        let result = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return kIOReturnBadArgument }
            return write(service, DDCPacket.chipAddress, DDCPacket.hostAddress, base, UInt32(raw.count))
        }
        guard result == kIOReturnSuccess else { throw DDCError.io(result) }
    }

    /// In the I/O Registry each external display's framebuffer (`IOMobileFramebufferShim` or
    /// `AppleCLCD2`, which carries the EDID attributes) comes right before its
    /// `DCPAVServiceProxy`, so the two are paired by walking the tree in order.
    private static func scanExternalServices() -> [DisplayIdentity: CFTypeRef] {
        guard let create = PrivateAPI.avServiceCreateWithService else { return [:] }
        var iterator = io_iterator_t()
        guard
            IORegistryCreateIterator(
                kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator)
                == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var found: [DisplayIdentity: CFTypeRef] = [:]
        var pending: DisplayIdentity?
        var name = [CChar](repeating: 0, count: 128)

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            IORegistryEntryGetName(entry, &name)
            switch String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                pending = identity(of: entry)
            case "DCPAVServiceProxy":
                defer { pending = nil }
                guard let identity = pending,
                    property("Location", of: entry) as? String == "External",
                    let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
                else { continue }
                found[identity] = service
            default:
                continue
            }
        }
        return found
    }

    private static func identity(of entry: io_registry_entry_t) -> DisplayIdentity? {
        guard let attributes = property("DisplayAttributes", of: entry) as? [String: Any],
            let product = attributes["ProductAttributes"] as? [String: Any],
            let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
            let model = (product["ProductID"] as? NSNumber)?.uint32Value
        else { return nil }
        let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
        return DisplayIdentity(vendor: vendor, model: model, serial: serial)
    }

    private static func property(_ key: String, of entry: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
