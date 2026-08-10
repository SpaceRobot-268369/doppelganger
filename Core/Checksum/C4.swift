import CryptoKit
import Foundation

/// ASC MHL's reference checksum: SHA-512 encoded as a fixed-width C4 ID.
/// C4 is used internally for manifest-chain integrity; it is intentionally not
/// exposed as a user-selectable media checksum.
enum C4Checksum {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func digest(_ data: Data) -> String {
        let bytes = Array(SHA512.hash(data: data))
        // Base conversion without a big-integer dependency. Digits are kept
        // little-endian while each input byte extends the base-256 number.
        var digits = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = digits[index] * 256 + carry
                digits[index] = value % 58
                carry = value / 58
            }
            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }
        let encoded = String(digits.reversed().map { alphabet[$0] })
        return "c4" + String(repeating: "1", count: max(0, 88 - encoded.count)) + encoded
    }
}
