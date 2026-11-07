import Foundation
import IOKit
import PrivateAPI

public enum DDCError: Error, Equatable, LocalizedError {
    case unavailable
    case io(Int32)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This monitor can't be controlled over DDC.", bundle: .module)
        case .io(let code): String(localized: "The monitor didn't respond to DDC (error \(code)).", bundle: .module)
        case .badReply: String(localized: "The monitor sent an invalid DDC reply.", bundle: .module)
        }
    }
}

public protocol DDCControlling: Sendable {
    func refresh() async
    func read(_ code: UInt8, from display: DisplayIdentity) async throws -> DDCPacket.Reply
    /// Many monitors drop a single write now and then.
    func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) async throws
    func capabilities(of display: DisplayIdentity) async throws -> String
}

extension DDCControlling {

    public func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity) async throws {
        try await write(code, value: value, to: display, attempts: 2)
    }
}

enum DDCExchange {
    static func read(
        _ code: UInt8, send: ([UInt8]) throws -> Void, receive: () throws -> [UInt8]
    ) throws -> DDCPacket.Reply {
        var lastError = DDCError.badReply
        for _ in 0..<3 {
            do {
                try send(DDCPacket.getVCP(code))
                // The monitor needs time to prepare its reply.
                usleep(40_000)
                if let reply = DDCPacket.parseReply(try receive(), code: code) { return reply }
                lastError = .badReply
            } catch let error as DDCError {
                lastError = error
            }
            usleep(20_000)
        }
        throw lastError
    }

    static func capabilities(send: ([UInt8]) throws -> Void, receive: () throws -> [UInt8]) throws -> String {
        var data: [UInt8] = []
        // The cap only stops a monitor that never ends the string.
        for _ in 0..<64 {
            let offset = UInt16(data.count)
            var chunk: [UInt8]?
            var lastError = DDCError.badReply
            for _ in 0..<3 where chunk == nil {
                do {
                    try send(DDCPacket.capabilitiesRequest(offset: offset))
                    usleep(50_000)
                    chunk = DDCPacket.parseCapabilitiesReply(try receive(), offset: offset)
                } catch let error as DDCError {
                    lastError = error
                }
                if chunk == nil { usleep(20_000) }
            }
            guard let chunk else { throw lastError }
            if chunk.isEmpty { break }
            data += chunk
        }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    static func write(_ code: UInt8, value: UInt16, attempts: Int, send: ([UInt8]) throws -> Void) throws {
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { usleep(20_000) }
            try send(DDCPacket.setVCP(code, value: value))
        }
    }
}

/// Calls block for tens of milliseconds, so they run on this actor.
public actor DDCService: DDCControlling {
    private var services: [DisplayIdentity: CFTypeRef] = [:]

    public init() {}

    public func refresh() {
        services = Self.scanExternalServices()
    }

    public func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply {
        let service = try service(for: display)
        return try DDCExchange.read(
            code, send: { try send($0, to: service) }, receive: { try receive(count: 12, from: service) })
    }

    public func capabilities(of display: DisplayIdentity) throws -> String {
        let service = try service(for: display)
        return try DDCExchange.capabilities(
            send: { try send($0, to: service) }, receive: { try receive(count: 38, from: service) })
    }

    public func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) throws {
        let service = try service(for: display)
        try DDCExchange.write(code, value: value, attempts: attempts) { try send($0, to: service) }
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

    private func receive(count: Int, from service: CFTypeRef) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, let readI2C = PrivateAPI.avServiceReadI2C else {
                return kIOReturnUnsupported
            }
            return readI2C(service, DDCPacket.chipAddress, DDCPacket.hostAddress, base, UInt32(raw.count))
        }
        guard result == kIOReturnSuccess else { throw DDCError.io(result) }
        return buffer
    }

    /// Each external display's framebuffer (`IOMobileFramebufferShim` or `AppleCLCD2`, which carries
    /// the EDID attributes) comes right before its `DCPAVServiceProxy` in the I/O Registry, so the
    /// two are paired by walking the tree in order.
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
