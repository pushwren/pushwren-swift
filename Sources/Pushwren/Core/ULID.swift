import Foundation

/// ULIDs: 48 bits of milliseconds, then 80 random bits, as 26 Crockford base32 characters.
/// They sort by creation time, which keeps device IDs in order on the server.
enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func make(now: Date = Date()) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((millis >> (8 * (5 - i))) & 0xff) }
        var rng = SystemRandomNumberGenerator()
        for i in 6..<16 { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        // 128 bits into 26 five-bit groups; the first group carries the top 3 bits.
        var out = [Character]()
        out.reserveCapacity(26)
        var acc: UInt32 = 0
        var bits = 2 // pad so 130 bits divide into 26 groups of 5
        for byte in bytes {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((acc >> UInt32(bits)) & 0x1f)])
            }
        }
        return String(out)
    }

    /// A Pushwren device ID: "dev_" and a ULID.
    static func deviceID(now: Date = Date()) -> String { "dev_" + make(now: now) }
}
