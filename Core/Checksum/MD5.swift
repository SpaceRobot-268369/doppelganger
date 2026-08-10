/// Streaming MD5 (RFC 1321), vendored in pure Swift like `XXHash64` so Core
/// stays dependency-free.
///
/// MD5 is here strictly for interchange: MHL workflows and facilities that
/// require MD5 digests. It is not a security primitive and nothing in
/// doppelganger treats it as one — both algorithms serve only to detect copy
/// corruption.
public struct MD5: StreamingHasher {
    private var a0: UInt32 = 0x6745_2301
    private var b0: UInt32 = 0xefcd_ab89
    private var c0: UInt32 = 0x98ba_dcfe
    private var d0: UInt32 = 0x1032_5476
    /// Bytes carried between updates; always fewer than 64.
    private var tail: [UInt8] = []
    private var totalBytes: UInt64 = 0

    public init() {}

    // MARK: - StreamingHasher

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        totalBytes &+= UInt64(buffer.count)

        var offset = 0
        if !tail.isEmpty {
            let take = Swift.min(64 - tail.count, buffer.count)
            tail.append(contentsOf: buffer[0..<take])
            offset = take
            guard tail.count == 64 else { return }
            let block = tail
            block.withUnsafeBytes { compress($0, at: 0) }
            tail.removeAll(keepingCapacity: true)
        }
        while offset + 64 <= buffer.count {
            compress(buffer, at: offset)
            offset += 64
        }
        if offset < buffer.count {
            tail.append(contentsOf: buffer[offset...])
        }
    }

    public func hexDigest() -> String {
        // Finalize a copy: the hasher itself may keep receiving data.
        var copy = self
        copy.appendPadding()
        var out = String()
        out.reserveCapacity(32)
        for word in [copy.a0, copy.b0, copy.c0, copy.d0] {
            var value = word.littleEndian
            withUnsafeBytes(of: &value) { bytes in
                for byte in bytes {
                    out += String(format: "%02x", byte)
                }
            }
        }
        return out
    }

    /// RFC 1321 padding: 0x80, zeros to 56 mod 64, then the bit length as a
    /// little-endian 64-bit integer.
    private mutating func appendPadding() {
        let bitLength = totalBytes &* 8
        var padding: [UInt8] = [0x80]
        let remainder = (Int(totalBytes % 64) + 1) % 64
        let zeros = remainder <= 56 ? 56 - remainder : 120 - remainder
        padding.append(contentsOf: repeatElement(0, count: zeros))
        var length = bitLength.littleEndian
        withUnsafeBytes(of: &length) { padding.append(contentsOf: $0) }
        padding.withUnsafeBytes { raw in
            // `update` would grow totalBytes; feed blocks directly.
            var offset = 0
            if !tail.isEmpty {
                let take = 64 - tail.count
                tail.append(contentsOf: raw[0..<take])
                let block = tail
                block.withUnsafeBytes { compress($0, at: 0) }
                tail.removeAll(keepingCapacity: true)
                offset = take
            }
            while offset + 64 <= raw.count {
                compress(raw, at: offset)
                offset += 64
            }
            precondition(offset == raw.count, "MD5 padding must end on a block boundary")
        }
    }

    // MARK: - Compression

    /// Per-round rotate amounts.
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// K[i] = floor(2³² × |sin(i + 1)|), fixed by the RFC.
    private static let k: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee,
        0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be,
        0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa,
        0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed,
        0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c,
        0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05,
        0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039,
        0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1,
        0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    private mutating func compress(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(littleEndian: bytes.loadUnaligned(
                fromByteOffset: offset + i * 4, as: UInt32.self))
        }

        var a = a0, b = b0, c = c0, d = d0
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16:
                f = (b & c) | (~b & d)
                g = i
            case 16..<32:
                f = (d & b) | (~d & c)
                g = (5 * i + 1) % 16
            case 32..<48:
                f = b ^ c ^ d
                g = (3 * i + 5) % 16
            default:
                f = c ^ (b | ~d)
                g = (7 * i) % 16
            }
            f = f &+ a &+ Self.k[i] &+ m[g]
            a = d
            d = c
            c = b
            b = b &+ (f << Self.s[i] | f >> (32 - Self.s[i]))
        }

        a0 &+= a
        b0 &+= b
        c0 &+= c
        d0 &+= d
    }
}
