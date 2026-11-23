import Foundation
import Testing
@testable import Importing

// M4.5 fuzzy re-anchor (SPEC §7 step 3): approximate quote match with Hypothesis weights.

@Suite struct FuzzyQuoteMatcherTests {
    private let chapter = """
        The rain had stopped by the time she reached the bridge. Below, the river was high and \
        brown, carrying branches and the odd plastic crate toward the sea. She leaned on the rail \
        and watched the water for a long time, thinking about nothing in particular. Then she \
        turned, walked back up the hill, and let herself into the empty house.
        """

    private func chars(_ s: String, _ r: Range<Int>) -> String { String(Array(s)[r]) }

    @Test func smallEditInsideQuoteMatchesFuzzily() throws {
        let quote = "She leaned on the rail and watched the water for a long time"
        let edited = chapter.replacingOccurrences(of: "leaned on the rail", with: "leant on the railing")
        let match = try #require(FuzzyQuoteMatcher.match(
            quote: quote, prefix: "toward the sea. ", suffix: ", thinking about", in: edited, progressionHint: 0.5))
        #expect(match.score >= FuzzyQuoteMatcher.acceptThreshold)
        #expect(match.score < 1)
        let found = chars(edited, match.range)
        #expect(found.hasPrefix("She leant"))
        #expect(found.hasSuffix("for a long time"))
    }

    @Test func editInContextOnlyStillScoresHigh() throws {
        let quote = "carrying branches and the odd plastic crate"
        let edited = chapter.replacingOccurrences(of: "high and brown", with: "swollen and muddy")
        let match = try #require(FuzzyQuoteMatcher.match(
            quote: quote, prefix: "river was high and brown, ", suffix: " toward the sea.", in: edited, progressionHint: nil))
        #expect(chars(edited, match.range) == quote)
        #expect(match.score >= FuzzyQuoteMatcher.acceptThreshold)
    }

    @Test func deletedPassageHasNoAcceptableMatch() {
        let quote = "She leaned on the rail and watched the water for a long time"
        let edited = chapter.replacingOccurrences(
            of: "She leaned on the rail and watched the water for a long time, thinking about nothing in particular. ",
            with: "")
        let match = FuzzyQuoteMatcher.match(
            quote: quote, prefix: "toward the sea. ", suffix: ", thinking about", in: edited, progressionHint: 0.5)
        #expect(match == nil || match!.score < FuzzyQuoteMatcher.acceptThreshold)
    }

    @Test func whitespaceDifferencesAreIgnored() throws {
        let quote = "walked back\nup the hill"
        let match = try #require(FuzzyQuoteMatcher.match(
            quote: quote, prefix: "she turned, ", suffix: ", and let", in: chapter, progressionHint: nil))
        #expect(chars(chapter, match.range) == "walked back up the hill")
        #expect(match.score == 1)
    }

    @Test func emptyInputsReturnNil() {
        #expect(FuzzyQuoteMatcher.match(quote: "", prefix: "", suffix: "", in: chapter, progressionHint: nil) == nil)
        #expect(FuzzyQuoteMatcher.match(quote: "rain", prefix: "", suffix: "", in: "", progressionHint: nil) == nil)
    }

    @Test func contextPicksBetweenTwoNearMatches() throws {
        let text = "Alpha said the old man was tired. Beta said the old men were tired."
        let match = try #require(FuzzyQuoteMatcher.match(
            quote: "the old man were tired", prefix: "Beta said ", suffix: ".", in: text, progressionHint: nil))
        #expect(chars(text, match.range) == "the old men were tired")
    }

    @Test func longChapterStaysFast() throws {
        let filler = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 2_000)
        let text = filler + "The quick brown fox jumps over the lazy dog near the riverbank. " + filler
        let quote = String(repeating: "x", count: 0) + "The quick brown fax jumped over the lazy dog near the riverbank"
        let start = ContinuousClock.now
        let match = try #require(FuzzyQuoteMatcher.match(
            quote: quote, prefix: "adipiscing elit. ", suffix: ". Lorem", in: text, progressionHint: 0.5))
        let elapsed = ContinuousClock.now - start
        #expect(chars(text, match.range).hasPrefix("The quick brown fox"))
        #expect(elapsed < .seconds(2))
    }
}
