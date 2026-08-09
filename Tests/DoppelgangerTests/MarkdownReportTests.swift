import Testing
@testable import Doppelganger

struct MarkdownReportTests {
    @Test func verifiedReportHasQuietGreenVerdictAndNoProblemsSection() {
        let markdown = MarkdownReportWriter.markdown(for: TransferManifest(report: ReportFixtures.verifiedReport()))
        #expect(markdown.contains("✅ VERIFIED"))
        #expect(!markdown.contains("## ⚠️ Problems"))
        #expect(markdown.contains("`DCIM/100MEDIA/A001.MP4`"))
        #expect(markdown.contains("`0123456789abcdef`"))
        #expect(markdown.contains("1.23 MB"))
    }

    @Test func failedReportIsLoudAndSpecific() {
        let markdown = MarkdownReportWriter.markdown(for: TransferManifest(report: ReportFixtures.failedReport()))
        #expect(markdown.contains("❌ FAILED"))
        #expect(markdown.contains("Do not erase the source media"))
        #expect(markdown.contains("## ⚠️ Problems — 3 file/destination pair(s) did NOT verify"))
        #expect(markdown.contains("checksum-mismatch"))
        #expect(markdown.contains("source-unreadable"))
        #expect(markdown.contains("destination-unavailable"))
        // The per-file table shows the mixed outcome, never one green checkmark.
        #expect(markdown.contains("| `DCIM/100MEDIA/A001.MP4` | 1.23 MB | `0123456789abcdef` | ✅ verified | ❌ checksum-mismatch |"))
    }

    @Test func cancelledReportWarnsAgainstTrustingCopies() {
        var manifest = TransferManifest(report: ReportFixtures.failedReport())
        manifest.status = "cancelled"
        let markdown = MarkdownReportWriter.markdown(for: manifest)
        #expect(markdown.contains("⛔️ CANCELLED"))
        #expect(markdown.contains("Do not treat these copies as complete"))
    }

    @Test func byteFormattingIsStable() {
        #expect(MarkdownReportWriter.byteString(0) == "0 B")
        #expect(MarkdownReportWriter.byteString(999) == "999 B")
        #expect(MarkdownReportWriter.byteString(1_000) == "1.0 KB")
        #expect(MarkdownReportWriter.byteString(1_234_567) == "1.23 MB")
        #expect(MarkdownReportWriter.byteString(5_000_000_000) == "5.0 GB")
    }

    @Test func pipesInPathsAreEscaped() {
        var manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        manifest.items[0].relativePath = "weird|name.mov"
        let markdown = MarkdownReportWriter.markdown(for: manifest)
        #expect(markdown.contains("weird\\|name.mov"))
    }
}
