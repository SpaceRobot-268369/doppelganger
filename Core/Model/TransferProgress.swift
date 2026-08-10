import Foundation

/// The distinct stages of a transfer. Progress at the end of `copying` means
/// the copy pass finished, nothing more — success exists only after
/// `verifying` completes cleanly.
public enum TransferPhase: String, Sendable, Codable, CaseIterable {
    case enumerating
    case preReadingSource
    case copying
    case verifying
    case writingManifest
    case done
}

/// A snapshot of where the transfer is. Derived, not authoritative: a byte
/// counter at 100% is never success — only the completed verification pass is.
public struct TransferProgress: Sendable {
    public var phase: TransferPhase
    public var totalBytes: Int64
    public var itemsTotal: Int
    /// Bytes written during the copy pass (per destination, the same bytes go
    /// to each live destination).
    public var copiedBytes: Int64
    /// Bytes accepted by each independent destination writer.
    public var copiedBytesByDestination: [URL: Int64]
    public var itemsCopied: Int
    /// Bytes re-read and hashed so far at each destination during verify.
    public var verifiedBytesByDestination: [URL: Int64]
    public var currentRelativePath: String?

    public init(
        phase: TransferPhase,
        totalBytes: Int64 = 0,
        itemsTotal: Int = 0,
        copiedBytes: Int64 = 0,
        copiedBytesByDestination: [URL: Int64] = [:],
        itemsCopied: Int = 0,
        verifiedBytesByDestination: [URL: Int64] = [:],
        currentRelativePath: String? = nil
    ) {
        self.phase = phase
        self.totalBytes = totalBytes
        self.itemsTotal = itemsTotal
        self.copiedBytes = copiedBytes
        self.copiedBytesByDestination = copiedBytesByDestination
        self.itemsCopied = itemsCopied
        self.verifiedBytesByDestination = verifiedBytesByDestination
        self.currentRelativePath = currentRelativePath
    }
}
