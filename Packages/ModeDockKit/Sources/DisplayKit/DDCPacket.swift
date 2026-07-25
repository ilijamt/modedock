/// DDC/CI (MCCS) packet encoding. The display's I²C address is 0x37; the host sends from 0x51
/// and the display replies to 0x50.
public enum DDCPacket {
    public static let chipAddress: UInt32 = 0x37
    public static let hostAddress: UInt32 = 0x51

    public enum VCP {
        public static let brightness: UInt8 = 0x10
        public static let powerMode: UInt8 = 0xD6
        public static let inputSource: UInt8 = 0x60
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

    /// Asks for the part of the monitor's capabilities string that starts at `offset`.
    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        withChecksum([0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)], seed: 0x6E ^ 0x51)
    }

    /// Reply layout: 6E <0x80 | length> E3 <offsetHi> <offsetLo> <data…> <checksum>, where length
    /// counts E3, the offset and the data. Returns the data (empty at the end of the string).
    public static func parseCapabilitiesReply(_ bytes: [UInt8], offset: UInt16) -> [UInt8]? {
        guard bytes.count >= 6, bytes[0] == 0x6E, bytes[1] & 0x80 != 0, bytes[2] == 0xE3 else { return nil }
        let length = Int(bytes[1] & 0x7F)
        guard length >= 3, bytes.count > 2 + length,
            UInt16(bytes[3]) << 8 | UInt16(bytes[4]) == offset,
            checksum(bytes[..<(2 + length)], seed: 0x50) == bytes[2 + length]
        else { return nil }
        return Array(bytes[5..<(2 + length)])
    }

    /// The input sources listed for VCP 0x60 in a capabilities string such as
    /// "(prot(monitor)…vcp(02 10 60(0F 11 12) D6(01 04))…)".
    public static func inputSources(inCapabilities capabilities: String) -> [UInt8] {
        let text = capabilities.uppercased()
        guard let match = text.firstMatch(of: /(?:^|[^0-9A-F])60\(([0-9A-F ]*)\)/) else { return [] }
        let digits = match.1.filter { $0 != " " }
        return stride(from: 0, to: digits.count - 1, by: 2).compactMap { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return UInt8(digits[start...digits.index(after: start)], radix: 16)
        }
    }

    /// MCCS names for the common input source values.
    public static func inputName(_ input: UInt8) -> String {
        switch input {
        case 0x01, 0x02: "VGA \(input)"
        case 0x03, 0x04: "DVI \(input - 0x02)"
        case 0x0F, 0x10: "DisplayPort \(input - 0x0E)"
        case 0x11, 0x12: "HDMI \(input - 0x10)"
        case 0x1B: "USB-C"
        default: String(localized: "Input \(String(format: "%02X", input))", bundle: .module)
        }
    }

    static func withChecksum(_ data: [UInt8], seed: UInt8) -> [UInt8] {
        data + [checksum(data[...], seed: seed)]
    }

    static func checksum(_ data: ArraySlice<UInt8>, seed: UInt8) -> UInt8 {
        data.reduce(seed, ^)
    }
}
