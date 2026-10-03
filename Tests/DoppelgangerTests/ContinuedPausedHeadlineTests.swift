import Foundation
import Testing
@testable import Doppelganger

/// A paused card promises Resume only until a linked resume or repair attempt
/// takes it over; after that its headline points to the linked attempt. The
/// attempt-lifecycle owner sets `TransferSession.continuedInLinkedAttempt`;
/// these tests pin the wording that flag selects. No `TransferSession` is
/// constructed: its init writes a journal under Application Support.
struct ContinuedPausedHeadlineTests {
    private static let resumeAvailableKey = "Paused safely · Resume available"
    private static let continuedKey = "Paused · continued in a linked attempt"

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

    // MARK: - Headline

    @Test func pausedHeadlinePromisesResumeUntilALinkedAttemptTakesOver() {
        #expect(
            TransferSession.pausedHeadline(continuedInLinkedAttempt: false)
                == L10n.text(Self.resumeAvailableKey)
        )
    }

    @Test func pausedHeadlineContinuedInALinkedAttemptStopsPromisingResume() {
        let continued = TransferSession.pausedHeadline(continuedInLinkedAttempt: true)
        #expect(continued == L10n.text(Self.continuedKey))
        #expect(continued != TransferSession.pausedHeadline(continuedInLinkedAttempt: false))
    }

    @Test func continuedWordingStillSaysPausedAndNeverResume() {
        // The development-language key is what an English card shows.
        #expect(Self.continuedKey.hasPrefix("Paused · "))
        #expect(!Self.continuedKey.localizedCaseInsensitiveContains("resume"))
        #expect(!Self.continuedKey.localizedCaseInsensitiveContains("available"))
    }

    // MARK: - Simplified Chinese

    @Test func simplifiedChineseContinuedHeadlineDropsTheResumePromise() throws {
        let catalog = try Self.simplifiedChineseCatalog()
        let resumeAvailable = try #require(catalog[Self.resumeAvailableKey])
        let continued = try #require(catalog[Self.continuedKey])
        #expect(continued != Self.continuedKey, "zh-Hans value equals its key")
        #expect(continued != resumeAvailable)
        // "可以继续" is the paused card's "Resume available" promise.
        #expect(resumeAvailable.contains("可以继续"))
        #expect(!continued.contains("可以继续"))
        // It still opens with the paused status word, as the tile text does.
        #expect(continued.hasPrefix("已暂停"))
    }
}
