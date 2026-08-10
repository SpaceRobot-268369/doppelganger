import Foundation
import xxHash

/// Streaming XXH3-64 backed by the official xxHash C implementation. The
/// state remains bounded regardless of media size.
public final class XXH3Streaming: StreamingHasher, @unchecked Sendable {
    private let state: OpaquePointer

    public init() {
        guard let state = XXH3_createState() else {
            preconditionFailure("XXH3 could not allocate its streaming state")
        }
        self.state = state
        guard XXH3_64bits_reset(state) == XXH_OK else {
            preconditionFailure("XXH3 could not initialize its streaming state")
        }
    }

    deinit {
        XXH3_freeState(state)
    }

    public func update(_ buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty, let baseAddress = buffer.baseAddress else { return }
        let result = XXH3_64bits_update(state, baseAddress, buffer.count)
        precondition(result == XXH_OK, "XXH3 could not update its streaming state")
    }

    public func hexDigest() -> String {
        String(format: "%016llx", XXH3_64bits_digest(state))
    }
}
