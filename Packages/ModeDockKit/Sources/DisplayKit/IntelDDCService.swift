import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

/// Untested: no Intel Mac was available to try it on.
public actor IntelDDCService: DDCControlling {
    private var framebuffers: [DisplayIdentity: io_service_t] = [:]

    public init() {}

    deinit {
        for framebuffer in framebuffers.values { IOObjectRelease(framebuffer) }
    }

    public func refresh() {
        for framebuffer in framebuffers.values { IOObjectRelease(framebuffer) }
        framebuffers = Self.scanFramebuffers()
    }

    public func read(_ code: UInt8, from display: DisplayIdentity) throws -> DDCPacket.Reply {
        let framebuffer = try framebuffer(for: display)
        return try DDCExchange.read(
            code, send: { try send($0, to: framebuffer) }, receive: { try receive(count: 11, from: framebuffer) })
    }

    public func capabilities(of display: DisplayIdentity) throws -> String {
        let framebuffer = try framebuffer(for: display)
        return try DDCExchange.capabilities(
            send: { try send($0, to: framebuffer) }, receive: { try receive(count: 38, from: framebuffer) })
    }

    public func write(_ code: UInt8, value: UInt16, to display: DisplayIdentity, attempts: Int) throws {
        let framebuffer = try framebuffer(for: display)
        try DDCExchange.write(code, value: value, attempts: attempts) { try send($0, to: framebuffer) }
    }

    private func framebuffer(for display: DisplayIdentity) throws -> io_service_t {
        if framebuffers.isEmpty { refresh() }
        guard let framebuffer = framebuffers[display] else { throw DDCError.unavailable }
        return framebuffer
    }

    /// Unlike IOAVService, the I²C request carries the host address as the first data byte.
    private func send(_ packet: [UInt8], to framebuffer: io_service_t) throws {
        var bytes = [UInt8(DDCPacket.hostAddress)] + packet
        try bytes.withUnsafeMutableBytes { raw in
            var request = IOI2CRequest()
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            request.sendAddress = DDCPacket.chipAddress << 1
            request.sendBuffer = vm_address_t(bitPattern: raw.baseAddress)
            request.sendBytes = UInt32(raw.count)
            try perform(&request, on: framebuffer)
        }
    }

    private func receive(count: Int, from framebuffer: io_service_t) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { raw in
            var request = IOI2CRequest()
            request.sendTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
            request.replyAddress = DDCPacket.chipAddress << 1 | 1
            request.replySubAddress = UInt8(DDCPacket.hostAddress)
            request.replyBuffer = vm_address_t(bitPattern: raw.baseAddress)
            request.replyBytes = UInt32(raw.count)
            try perform(&request, on: framebuffer)
        }
        return bytes
    }

    private func perform(_ request: inout IOI2CRequest, on framebuffer: io_service_t) throws {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS, busCount > 0 else {
            throw DDCError.unavailable
        }
        var lastResult = kIOReturnNotFound
        for bus in 0..<busCount {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(interface) }
            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else { continue }
            defer { IOI2CInterfaceClose(connect, 0) }
            lastResult = IOI2CSendRequest(connect, 0, &request)
            if lastResult == KERN_SUCCESS && request.result == KERN_SUCCESS { return }
            if lastResult == KERN_SUCCESS { lastResult = request.result }
        }
        throw DDCError.io(lastResult)
    }

    private static func scanFramebuffers() -> [DisplayIdentity: io_service_t] {
        var iterator = io_iterator_t()
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator)
                == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var found: [DisplayIdentity: io_service_t] = [:]
        while case let framebuffer = IOIteratorNext(iterator), framebuffer != 0 {
            guard
                let info = IODisplayCreateInfoDictionary(framebuffer, IOOptionBits(kIODisplayOnlyPreferredName))?
                    .takeRetainedValue() as? [String: Any],
                let vendor = (info[kDisplayVendorID] as? NSNumber)?.uint32Value,
                let model = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            else {
                IOObjectRelease(framebuffer)
                continue
            }
            let serial = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0
            let identity = DisplayIdentity(vendor: vendor, model: model, serial: serial)
            if let previous = found.updateValue(framebuffer, forKey: identity) { IOObjectRelease(previous) }
        }
        return found
    }
}

public func makeDDCService() -> DDCControlling {
    #if arch(x86_64)
        IntelDDCService()
    #else
        DDCService()
    #endif
}
