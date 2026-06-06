/// DDC/CI (MCCS) packet encoding. The display's I²C address is 0x37; the host sends from 0x51
/// and the display replies to 0x50.
public enum DDCPacket {
    public static let chipAddress: UInt32 = 0x37
    public static let hostAddress: UInt32 = 0x51

    public enum VCP {
        public static let powerMode: UInt8 = 0xD6
    }

    public enum PowerMode {
        public static let on: UInt16 = 0x01
        /// DPM off: the monitor blanks and powers down its panel, but still listens on DDC.
        public static let off: UInt16 = 0x04
    }

    public struct Reply: Equatable, Sendable {
        public let current: UInt16
        public let maximum: UInt16

        public init(current: UInt16, maximum: UInt16) {
            self.current = current
            self.maximum = maximum
        }
    }

    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)], seed: 0x6E ^ 0x51)
    }

    public static func getVCP(_ code: UInt8) -> [UInt8] {
        withChecksum([0x82, 0x01, code], seed: 0x6E ^ 0x51)
    }

    /// Reply layout: 6E 88 02 <result> <code> <type> <maxHi> <maxLo> <curHi> <curLo> <checksum>.
    public static func parseReply(_ bytes: [UInt8], code: UInt8) -> Reply? {
        guard bytes.count >= 11 else { return nil }
        let reply = Array(bytes.prefix(11))
        guard reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code,
            checksum(reply.dropLast(), seed: 0x50) == reply[10]
        else { return nil }
        return Reply(
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            maximum: UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    static func withChecksum(_ data: [UInt8], seed: UInt8) -> [UInt8] {
        data + [checksum(data[...], seed: seed)]
    }

    static func checksum(_ data: ArraySlice<UInt8>, seed: UInt8) -> UInt8 {
        data.reduce(seed, ^)
    }
}
