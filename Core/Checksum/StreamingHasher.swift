/// A checksum that is fed bounded chunks and finalized once the stream ends.
///
/// Media files run to hundreds of gigabytes; nothing in Core may hash a whole
/// file in memory. The engine owns the chunk loop and calls `update` per chunk.
public protocol StreamingHasher: Sendable {
    mutating func update(_ buffer: UnsafeRawBufferPointer)

    /// The digest of everything fed so far, rendered as lowercase hex.
    /// Non-mutating: the hasher may keep receiving data afterwards.
    func hexDigest() -> String
}

extension StreamingHasher {
    /// Feed the first `count` bytes of `bytes`.
    public mutating func update(_ bytes: [UInt8], count: Int) {
        bytes.withUnsafeBytes { raw in
            update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
        }
    }
}
