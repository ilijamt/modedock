import Testing

@testable import DisplayKit

struct DDCPacketTests {
    @Test func setPowerModeOff() {
        // 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0xD6 ^ 0x00 ^ 0x04
        #expect(
            DDCPacket.setVCP(0xD6, value: 4) == [0x84, 0x03, 0xD6, 0x00, 0x04, 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0xD6 ^ 0x04])
    }

    @Test func setSplitsValueIntoHighAndLowBytes() {
        let packet = DDCPacket.setVCP(0x10, value: 0x0150)
        #expect(packet[3] == 0x01)
        #expect(packet[4] == 0x50)
    }

    @Test func getRequest() {
        #expect(DDCPacket.getVCP(0xD6) == [0x82, 0x01, 0xD6, 0x6E ^ 0x51 ^ 0x82 ^ 0x01 ^ 0xD6])
    }

    private func reply(code: UInt8, result: UInt8 = 0, max: UInt16, current: UInt16) -> [UInt8] {
        let body: [UInt8] = [
            0x6E, 0x88, 0x02, result, code, 0x00,
            UInt8(max >> 8), UInt8(max & 0xFF), UInt8(current >> 8), UInt8(current & 0xFF),
        ]
        return body + [body.reduce(0x50, ^), 0x00]
    }

    @Test func parsesValidReply() {
        let parsed = DDCPacket.parseReply(reply(code: 0xD6, max: 5, current: 1), code: 0xD6)
        #expect(parsed == DDCPacket.Reply(current: 1, maximum: 5))
    }

    @Test func rejectsBadChecksum() {
        var bytes = reply(code: 0xD6, max: 5, current: 1)
        bytes[10] ^= 0xFF
        #expect(DDCPacket.parseReply(bytes, code: 0xD6) == nil)
    }

    @Test func rejectsUnsupportedCodeOrWrongCode() {
        #expect(DDCPacket.parseReply(reply(code: 0xD6, result: 1, max: 5, current: 1), code: 0xD6) == nil)
        #expect(DDCPacket.parseReply(reply(code: 0x10, max: 100, current: 50), code: 0xD6) == nil)
    }

    @Test func rejectsShortOrEmptyReply() {
        #expect(DDCPacket.parseReply([0x6E, 0x88], code: 0xD6) == nil)
        #expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 12), code: 0xD6) == nil)
    }

    @Test func capabilitiesRequestAndReply() {
        #expect(
            DDCPacket.capabilitiesRequest(offset: 0x20) == [0x83, 0xF3, 0x00, 0x20, 0x6E ^ 0x51 ^ 0x83 ^ 0xF3 ^ 0x20])
        let data: [UInt8] = Array("vcp(60".utf8)
        var reply: [UInt8] = [0x6E, 0x80 | UInt8(3 + data.count), 0xE3, 0x00, 0x20] + data
        reply.append(reply.reduce(0x50, ^))
        #expect(DDCPacket.parseCapabilitiesReply(reply, offset: 0x20) == data)
        #expect(DDCPacket.parseCapabilitiesReply(reply, offset: 0x00) == nil)
    }

    @Test func inputSourcesFromCapabilities() {
        let samsung = "(prot(monitor)vcp(02 10 14(01 04) DC(00 60) 60(01 03) 62 FF)mccs_ver(2.0))"
        #expect(DDCPacket.inputSources(inCapabilities: samsung) == [0x01, 0x03])
        #expect(DDCPacket.inputSources(inCapabilities: "vcp(60(0f1112))") == [0x0F, 0x11, 0x12])
        #expect(DDCPacket.inputSources(inCapabilities: "vcp(10 12)").isEmpty)
        #expect(DDCPacket.inputName(0x11) == "HDMI 1")
        #expect(DDCPacket.inputName(0x10) == "DisplayPort 2")
    }
}

struct DisplayPolicyTests {
    @Test func cannotDisableLastDisplay() {
        #expect(!DisplayPolicy.canDisable(1, enabled: [1]))
    }

    @Test func canDisableWhenAnotherStaysOn() {
        #expect(DisplayPolicy.canDisable(1, enabled: [1, 5]))
    }

    @Test func cannotDisableAlreadyDisabled() {
        #expect(!DisplayPolicy.canDisable(5, enabled: [1, 2]))
    }
}
