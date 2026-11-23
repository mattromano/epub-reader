import Foundation
import Testing
@testable import Importing

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xhtml", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// The Characters of `text` in `range`.
private func slice(_ text: String, _ range: Range<Int>) -> String {
    String(Array(text)[range])
}

/// Character offsets of every occurrence of `needle` in `text`.
private func characterStarts(of needle: String, in text: String) -> [Int] {
    text.ranges(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
}

@Suite struct QuoteLocatorTests {
    @Test func exactUniqueQuote() throws {
        let text = "The quick brown fox jumps over the lazy dog."
        let range = try #require(QuoteLocator.locate(quote: "brown fox", prefix: "", suffix: "", in: text))
        #expect(range == 10..<19)
        #expect(slice(text, range) == "brown fox")
    }

    @Test func ambiguousResolvedByPrefix() throws {
        let text = "red cat sat. blue cat sat. green cat sat."
        let range = try #require(QuoteLocator.locate(quote: "cat sat", prefix: "blue ", suffix: "", in: text))
        #expect(range.lowerBound == characterStarts(of: "cat sat", in: text)[1])
        #expect(slice(text, range) == "cat sat")
    }

    @Test func ambiguousResolvedBySuffix() throws {
        let text = "the cat ran. the cat hid. the cat ate."
        let range = try #require(QuoteLocator.locate(quote: "the cat", prefix: "", suffix: " ate", in: text))
        #expect(range.lowerBound == characterStarts(of: "the cat", in: text)[2])
    }

    @Test func prefixAndSuffixCombine() throws {
        // Occurrence 0 matches more prefix; occurrence 1 matches prefix + suffix and wins.
        let text = "xx ab Q cd. yy b Q cdef."
        let range = try #require(QuoteLocator.locate(quote: "Q", prefix: "ab ", suffix: " cdef", in: text))
        #expect(range.lowerBound == characterStarts(of: "Q", in: text)[1])
    }

    @Test func tieResolvedByHint() throws {
        let text = "echo. echo. echo. echo."
        let starts = characterStarts(of: "echo", in: text)
        let late = try #require(QuoteLocator.locate(quote: "echo", prefix: "", suffix: "", in: text,
                                                    progressionHint: 0.8))
        #expect(late.lowerBound == starts[3])
        let middle = try #require(QuoteLocator.locate(quote: "echo", prefix: ". ", suffix: ".", in: text,
                                                      progressionHint: 0.3))
        // Same context score for occurrences 1–3 (occurrence 0 has no prefix); 0.3 * 23 ≈ 6.9 → offset 6.
        #expect(middle.lowerBound == starts[1])
    }

    @Test func tieWithoutHintPicksFirst() throws {
        let text = "echo. echo. echo."
        let range = try #require(QuoteLocator.locate(quote: "echo", prefix: "", suffix: "", in: text))
        #expect(range == 0..<4)
    }

    @Test func readiumShapedContextAcrossBlocks() throws {
        let xhtml = """
            <html><body>
              <p>One two three.</p>
              <p>Alpha beta gamma.</p>
              <p>One two three.</p>
              <p>Delta beta gamma.</p>
            </body></html>
            """
        let text = TextNormalizer.normalize(xhtml: xhtml).text
        #expect(text == "One two three. Alpha beta gamma. One two three. Delta beta gamma.")
        // textContent of adjacent <p>s: raw source whitespace or none at all between blocks;
        // selection.toString() puts "\n" between blocks.
        let range = try #require(QuoteLocator.locate(
            quote: "three.\nDelta beta", prefix: "gamma.\n  One two ", suffix: " gamma.", in: text))
        #expect(slice(text, range) == "three. Delta beta")
        #expect(range.lowerBound == characterStarts(of: "three.", in: text)[1])

        let beta = try #require(QuoteLocator.locate(
            quote: "beta", prefix: "three.Alpha ", suffix: "gamma.One", in: text))
        #expect(beta.lowerBound == characterStarts(of: "beta", in: text)[0])
    }

    @Test func nbspAndSoftHyphen() throws {
        let xhtml = "<p>A hy&shy;phen&shy;ation&nbsp;test here. Then hyphenation again.</p>"
        let text = TextNormalizer.normalize(xhtml: xhtml).text
        #expect(text == "A hyphenation test here. Then hyphenation again.")
        // Readium's DOM text still carries U+00AD and U+00A0.
        let range = try #require(QuoteLocator.locate(
            quote: "hy\u{AD}phen\u{AD}ation\u{A0}test", prefix: "A ", suffix: "", in: text))
        #expect(slice(text, range) == "hyphenation test")
        #expect(range.lowerBound == 2)
    }

    @Test func emojiAndCombiningCharactersUseCharacterOffsets() throws {
        let text = "👨‍👩‍👧 cafe\u{301} 🇯🇵 naïve target here"
        let range = try #require(QuoteLocator.locate(quote: "target", prefix: "", suffix: "", in: text))
        // 👨‍👩‍👧=0 ' ' c a f é=5 ' ' 🇯🇵=7 ' ' n a ï v e=13 ' ' t=15
        #expect(range.lowerBound == 15)
        #expect(slice(text, range) == "target")
        // Canonically equivalent composed form in the quote still matches.
        let cafe = try #require(QuoteLocator.locate(quote: "caf\u{E9}", prefix: "", suffix: "", in: text))
        #expect(cafe == 2..<6)
    }

    @Test func notFoundAndEmpty() {
        let text = "Some chapter text."
        #expect(QuoteLocator.locate(quote: "absent", prefix: "", suffix: "", in: text) == nil)
        #expect(QuoteLocator.locate(quote: "", prefix: "Some", suffix: "", in: text) == nil)
        #expect(QuoteLocator.locate(quote: " \n\u{AD} ", prefix: "", suffix: "", in: text) == nil)
        #expect(QuoteLocator.locate(quote: "x", prefix: "", suffix: "", in: "") == nil)
    }

    @Test func fixtureUniquePhrase() throws {
        let text = TextNormalizer.normalize(xhtml: try fixture("chapter_basic")).text
        let phrase = "jumps over the lazy dog"
        let expected = try #require(characterStarts(of: phrase, in: text).first)
        let range = try #require(QuoteLocator.locate(
            quote: "jumps over\n the lazy dog", prefix: "brown fox", suffix: ".Fish", in: text))
        #expect(range.lowerBound == expected)
        #expect(range.count == phrase.count)
    }

    @Test func fixtureAmbiguousResolvedByPrefix() throws {
        let text = TextNormalizer.normalize(xhtml: try fixture("chapter_basic")).text
        // "he" occurs in "The", "the" and "She".
        let starts = characterStarts(of: "he", in: text)
        #expect(starts.count >= 3)
        let she = try #require(characterStarts(of: "She", in: text).first)
        let range = try #require(QuoteLocator.locate(quote: "he", prefix: "bargain… S", suffix: " said", in: text))
        #expect(range.lowerBound == she + 1)
        let first = try #require(QuoteLocator.locate(quote: "he", prefix: "", suffix: "", in: text))
        #expect(first.lowerBound == starts[0])
    }

    @Test func pathologicalInputStaysFast() throws {
        let text = String(repeating: "a", count: 50_000)
        let quote = String(repeating: "a", count: 500) + "b"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(QuoteLocator.locate(quote: quote, prefix: "", suffix: "", in: text) == nil)
        }
        #expect(elapsed < .milliseconds(500))
    }

    @Test func largeChapterLocatesQuickly() throws {
        let words = ["amber", "birch", "cedar", "dune", "ember", "fjord", "grove", "heath"]
        // Unique tokens ("amber0 birch1 …"), so the target occurs once; the first letters repeat a lot.
        var parts: [String] = []
        var length = 0
        while length <= 100_001 {
            let word = words[parts.count % words.count] + String(parts.count)
            parts.append(word)
            length += word.count + 1
        }
        let text = parts.joined(separator: " ")
        #expect(text.count >= 100_000)
        let target = parts[parts.count * 3 / 4 ..< parts.count * 3 / 4 + 5].joined(separator: " ")
        let expected = try #require(characterStarts(of: target, in: text).first)

        let clock = ContinuousClock()
        var range: Range<Int>?
        let elapsed = clock.measure {
            range = QuoteLocator.locate(quote: target, prefix: "", suffix: "", in: text, progressionHint: 0.75)
        }
        #expect(range?.lowerBound == expected)
        // Generous: the goal is well under 50 ms in debug.
        #expect(elapsed < .milliseconds(250))
    }
}
