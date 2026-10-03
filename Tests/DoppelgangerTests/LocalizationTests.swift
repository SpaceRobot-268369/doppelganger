import Foundation
import Testing
@testable import Doppelganger

/// Every string the app builds at runtime and routes through `L10n` must have
/// a real Simplified Chinese entry. SwiftUI localizes static `Text("…")` keys
/// on its own; these dynamic keys are the ones a missing catalog entry would
/// silently leave in English.
struct LocalizationTests {
    /// Every literal key passed to `L10n.text("…")` or `L10n.format("…", …)`
    /// under `App/`, `Core/`, and `Platform/`. Regenerate when a dynamic
    /// string is added:
    ///
    ///     grep -rhoE 'L10n\.(text|format)\(\s*"[^"]*"' App Core Platform \
    ///         | sed -E 's/^L10n\.(text|format)\(\s*//' | sort -u
    ///
    /// (multi-line calls put the literal on the line after the paren; the
    /// list below includes those too).
    static let dynamicKeys: [String] = [
        "%@ FAILED",
        "%@ cancelled",
        "%@ free",
        "%@ is on the same physical device as the source; this is not an independent backup.",
        "%@ is on the same volume as the source; this is not an independent backup.",
        "%@ paused",
        "%@ share one physical volume; they are not independent copies.",
        "%@ transferred",
        "%@ verified",
        "%lld copies did not verify. Do not erase the source media.",
        "%lld errors",
        "%lld failures",
        "%lld files have no checksum in this reference, so they cannot be verified. Choose the manifest of a verified attempt.",
        "%lld files · %@",
        "%lld files × %lld destinations — every copy passed checksum verification.",
        "%lld files × 1 destination — every copy passed checksum verification.",
        "%lld recognized media · %lld sidecars",
        "%lld transfers",
        "1 failure",
        "1 file has no checksum in this reference, so it cannot be verified. Choose the manifest of a verified attempt.",
        "1 transfer",
        "A camera needs a reel letter, for example A or B.",
        "A camera-card source cannot also be its own destination volume.",
        "A camera-card source cannot share its physical device with a destination.",
        "A cascade's source is the verified destination it came from.",
        "A destination is a folder, so the folder holding those files was added.",
        "A destination is inside source %@.",
        "A linked attempt already continues this one. Use that attempt's card instead.",
        "Add at least one destination.",
        "All Operators",
        "At least one operator profile must remain active",
        "At least one operator profile must remain active.",
        "Avatar could not be imported: %@",
        "Cancel",
        "Cancelled · Incomplete",
        "Choose a source to offload.",
        "Connect the source %@ to resume this transfer.",
        "Contact sheet created at %lld evidence locations.",
        "Contact sheet was not created: %@",
        "Copies verified · transfer not verified",
        "Copy complete, but independent destination verification is still required. Keep the source media.",
        "Copying · %@",
        "Copying · %lld%%",
        "Could not eject source: %@",
        "Could not identify the physical device behind %@; the copies cannot be confirmed as independent.",
        "Destination %@ is not mounted.",
        "Destination benchmark failed: %@",
        "Drop something from Finder — a folder, a card, or files inside one.",
        "ETA",
        "Enter a transfer folder name.",
        "Every source in a batch needs a unique transfer folder name.",
        "Export failed: %@",
        "FILES",
        "Failed · %@",
        "Failed · %lld copy results failed",
        "Failed · 1 copy result failed",
        "Failed · transfer evidence incomplete",
        "Finishing…",
        "Generating contact sheet…",
        "ID",
        "Import failed: %@",
        "Incomplete",
        "Interrupted · Review required",
        "Keep Running",
        "Maximum · reading source…",
        "No active operator profile is available",
        "Not ejected: %lld other transfers still use this source.",
        "Not ejected: Doppelganger could not confirm this is the verified source volume.",
        "Not ejected: a different volume is now mounted where the verified source was.",
        "Not ejected: another transfer still uses this source.",
        "Not ejected: the verified source is no longer mounted.",
        "Paused safely · Resume available",
        "Paused · completed files retained",
        "Paused · continued in a linked attempt",
        "Pausing after the current file finishes",
        "Pausing after the current file finishes · %@",
        "Queued transfers have not started and will not run.",
        "Queued · waiting for a slot",
        "Quit Anyway",
        "Quitting interrupts active copies. Their partial output will be preserved and shown as needing attention next time Doppelganger opens.",
        "Reel letter %@ is already used by another camera on this project.",
        "Removed %lld temporary files.",
        "Removed %lld temporary files; %lld could not be removed.",
        "Resume needs every destination this transfer paused on. Reconnect %@, or use Retry as New Offload.",
        "Scanning source…",
        "Settings exported to %@.",
        "Settings imported and merged.",
        "Some paused or unverified transfers could not be saved for next time and will not reopen as they are now. Keep the source media.",
        "Some transfers cannot be restored",
        "Source %@ is inside a destination.",
        "Source %@ is not mounted.",
        "Source safely ejected.",
        "Sources in this batch would write the same files into one destination: %@. Choose New folder under Output so each source gets its own folder.",
        "Standalone verification failed: %@",
        "Started by %@",
        "Stopped at a complete-file boundary. Keep the source connected to resume.",
        "Stopped before completion — these copies are not complete. Do not erase the source media.",
        "The failed attempt's manifest is unavailable; use Retry as New Offload instead.",
        "The folder name for %@ changed after preflight. Run preflight again.",
        "The media folder could not be read completely: %@",
        "The paused attempt's manifest is unavailable; it cannot be resumed safely.",
        "The paused attempt's reviewed file scope cannot be confirmed; it cannot be resumed safely.",
        "The product catalog could not be opened. Changes will last for this launch only: %@",
        "The same destination is listed twice.",
        "The same source is listed twice.",
        "The selected profile is archived or missing",
        "The selected project is missing or archived",
        "The source could not be read completely: %@",
        "The transfer task could not be found",
        "This attempt has no failed file/destination pairs to retry.",
        "This exact source plan was verified before · %@ → %@",
        "This settings package uses unsupported schema version %lld.",
        "Those items could not be read. Nothing in the plan changed.",
        "Transfer rate",
        "Transferred · transfer not verified",
        "Transferred · verification pending",
        "Transferring only the %lld selected file(s). Nothing else in that folder is included.",
        "Transfers are still running",
        "Transfers are waiting to start",
        "Two sources would write to %@. Change the Reel Name or remove a source.",
        "Verified · %@",
        "Verified · Complete",
        "Verifying · %@",
        "Verifying · %lld%%",
        "Waiting",
        "Writing manifest…",
        "[folder per source]",
        "bottleneck",
        "in %@",
        "…and %lld more",
    ]

    /// Keys chosen by a `switch` and then passed to `L10n.text(key)` — the
    /// section, filter, appearance, and verdict titles.
    static let switchedKeys: [String] = [
        "Transfers", "Compare", "Projects", "Storage", "Manifests", "Help", "Settings",
        "All", "Active", "Needs Attention", "Verified",
        "System", "Light", "Dark",
        "Pending", "Paused", "Needs Verification", "Failed", "Cancelled",
    ]

    private static func simplifiedChineseCatalog() throws -> [String: String] {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(
            bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "zh-Hans"
            )
        )
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func everyDynamicKeyHasASimplifiedChineseTranslation() throws {
        let catalog = try Self.simplifiedChineseCatalog()
        let keys = Self.dynamicKeys + Self.switchedKeys
        #expect(Set(keys).count == keys.count, "duplicate key in the sweep list")

        var missing: [String] = []
        var untranslated: [String] = []
        for key in keys {
            guard let value = catalog[key], !value.isEmpty else {
                missing.append(key)
                continue
            }
            if value == key { untranslated.append(key) }
        }
        #expect(missing.isEmpty, "zh-Hans is missing: \(missing)")
        #expect(untranslated.isEmpty, "zh-Hans value equals its key: \(untranslated)")
    }

    @Test func sweepListStaysInSyncWithTheSource() throws {
        // The catalog test only proves what the list names. Guard the list
        // itself against drift: every L10n literal in the shipped sources must
        // be in it. The sources are not in the test bundle, so this walks up
        // from the test file to the repository root when it can.
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoots = ["App", "Core", "Platform"].map { root.appendingPathComponent($0) }
        guard sourceRoots.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return }

        let pattern = try NSRegularExpression(pattern: #"L10n\.(?:text|format)\(\s*"((?:[^"\\]|\\.)*)""#)
        var found = Set<String>()
        for sourceRoot in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                for match in pattern.matches(in: source, range: range) {
                    if let keyRange = Range(match.range(at: 1), in: source) {
                        found.insert(Self.unescaped(String(source[keyRange])))
                    }
                }
            }
        }
        let listed = Set(Self.dynamicKeys)
        let unlisted = found.subtracting(listed).sorted()
        let stale = listed.subtracting(found).sorted()
        #expect(unlisted.isEmpty, "L10n keys in source but not in the sweep list: \(unlisted)")
        #expect(stale.isEmpty, "sweep list names keys no longer in source: \(stale)")
    }

    /// Swift string-literal escapes that appear in keys (`\"` and `\\`).
    private static func unescaped(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
