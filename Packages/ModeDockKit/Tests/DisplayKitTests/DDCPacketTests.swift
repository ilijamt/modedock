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
