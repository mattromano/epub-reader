import CryptoKit
import Foundation
import NaturalLanguage
import Testing
@testable import Importing

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xhtml", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func chapter(_ spine: Int, _ xhtml: String, title: String? = "T", linear: Bool = true) -> IndexInputChapter {
    IndexInputChapter(spineIndex: spine, href: "OEBPS/ch\(spine).xhtml", title: title, isLinear: linear, xhtml: xhtml)
}

/// `<p>` of `n` distinct words ("w0 w1 …").
private func paragraph(words n: Int, from start: Int = 0) -> String {
    "<p>" + (start..<(start + n)).map { "w\($0)" }.joined(separator: " ") + "</p>"
}

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - TextNormalizer

@Suite struct TextNormalizerTests {
    @Test func fixtureNormalizesExactly() throws {
        let result = TextNormalizer.normalize(xhtml: try fixture("chapter_basic"))
        #expect(result.text == """
            Chapter One The quick brown fox jumps over the lazy dog. \
            Fish & chips cost $5 \u{2014} a bargain\u{2026} \
            She said \u{201C}hello\u{201D} and left. \
            Unknown &foo; stays, \u{00A9} 2026.
            """)
        // h1, p, p, p (split by <br/>), p.
        #expect(result.blockStarts == [0, 12, 57, 91, 108, 118])
    }

    @Test func fixtureWordCountMatchesNLTokenizer() throws {
        let input = chapter(0, try fixture("chapter_basic"))
        let indexed = WordIndexer.index([input])
        // Chapter One (2) · The quick brown fox jumps over the lazy dog (9) ·
        // Fish chips cost 5 a bargain (6; "&", "$", "—", "…" are not words) ·
        // She said hello (3) · and left (2) · Unknown foo stays 2026 (4; "©" is not a word).
        #expect(indexed[0].wordCount == 26)
        #expect(indexed[0].anchors.map(\.cumWordOffset) == [0, 2, 11, 17, 20, 22])
    }

    @Test func dropsHeadScriptStyleAndComments() {
        let xhtml = """
            <html><HEAD><title>x</title></HEAD><body><Script>alert("x")</Script>\
            <style>.a{}</style>a<!-- hidden -->b<script src="x.js"/>c<style/>d</body></html>
            """
        #expect(TextNormalizer.normalize(xhtml: xhtml).text == "abcd")
    }

    @Test func selfClosingHeadDoesNotSwallowBody() {
        #expect(TextNormalizer.normalize(xhtml: "<head/><p>kept</p>").text == "kept")
    }

    @Test func unclosedHeadResumesAtBody() {
        #expect(TextNormalizer.normalize(xhtml: "<head><title>x</title><body><p>kept</p>").text == "kept")
    }

    @Test func unclosedScriptDropsRest() {
        #expect(TextNormalizer.normalize(xhtml: "<p>a</p><script>var x").text == "a")
    }

    @Test func entities() {
        let r = TextNormalizer.normalize(xhtml: "&lt;a&gt; &quot;q&quot; &apos;s&apos; &#65;&#x42;&#X43; &lsquo;x&rsquo; &ndash; &mdash;")
        #expect(r.text == "<a> \"q\" 's' ABC \u{2018}x\u{2019} \u{2013} \u{2014}")
    }

    @Test func invalidNumericEntitiesStayLiteral() {
        let r = TextNormalizer.normalize(xhtml: "a&#0;b &#xD800; &#99999999999999; &#xZZ; & x &amp")
        #expect(r.text == "a&#0;b &#xD800; &#99999999999999; &#xZZ; & x &amp")
    }

    @Test func softHyphenDroppedEitherWay() {
        #expect(TextNormalizer.normalize(xhtml: "hy&shy;phen\u{00AD}ation").text == "hyphenation")
    }

    @Test func nbspCollapsesWithWhitespace() {
        #expect(TextNormalizer.normalize(xhtml: "  a&nbsp; \u{00A0}\n\tb  ").text == "a b")
    }

    @Test func inlineTagsDoNotSplitWords() {
        #expect(TextNormalizer.normalize(xhtml: "<p>wo<b>r</b><span>d</span></p>").text == "word")
    }

    @Test func adjacentBlocksDoNotMerge() {
        let r = TextNormalizer.normalize(xhtml: "<div>one</div><div>two</div><li>three</li>x<br>y<hr/>z")
        #expect(r.text == "one two three x y z")
        #expect(r.blockStarts == [0, 4, 8, 14, 16, 18])
    }

    @Test func emptyBlocksProduceNoStarts() {
        let r = TextNormalizer.normalize(xhtml: "<p></p><p>  </p><div><p>a</p></div><p/>")
        #expect(r.text == "a")
        #expect(r.blockStarts == [0])
    }

    @Test func literalLessThanAndCDATA() {
        #expect(TextNormalizer.normalize(xhtml: "<p>a < b</p><![CDATA[c & d]]>").text == "a < b c & d")
    }

    @Test func blockStartsAreCharacterOffsets() {
        // "é" as e + combining acute (2 scalars, 1 Character), and a flag emoji (2 scalars).
        let r = TextNormalizer.normalize(xhtml: "<p>e\u{0301}\u{1F1EB}\u{1F1F7}</p><p>x</p>")
        #expect(r.text.count == 4)
        #expect(r.blockStarts == [0, 3])
    }

    @Test func emptyInput() {
        #expect(TextNormalizer.normalize(xhtml: "") == NormalizedText(text: "", blockStarts: []))
        #expect(TextNormalizer.normalize(xhtml: "<html><head></head><body></body></html>").text == "")
    }
}

// MARK: - NLTokenizer findings (OPEN_QUESTIONS M2)

@Suite struct NLTokenizerFindingsTests {
    private func words(_ s: String) -> Int {
        WordIndexer.index([chapter(0, "<p>\(s)</p>")])[0].wordCount
    }

    @Test func contractionsAreOneWord() {
        #expect(words("Don't stop, it's John's car.") == 5)
        #expect(words("Don\u{2019}t stop.") == 2)
    }

    @Test func hyphenatedWordsSplit() {
        #expect(words("A well-known state-of-the-art idea.") == 8)
    }

    @Test func dashesAndPunctuationAreNotWords() {
        #expect(words("Wait\u{2014}what? Yes \u{2013} no\u{2026}") == 4)
    }

    @Test func numbersAreOneWordEach() {
        #expect(words("It cost $3.50 in 1999, 1,000 times.") == 7)
    }

    @Test func abbreviationsSplitOnPeriods() {
        #expect(words("U.S.A. Mr. Smith") == 5)
    }
}

// MARK: - WordIndexer

@Suite struct WordIndexerTests {
    @Test func cumWordsStartIsCumulative() {
        let chapters = WordIndexer.index([
            chapter(0, paragraph(words: 10)),
            chapter(1, paragraph(words: 20)),
            chapter(2, paragraph(words: 5)),
        ])
        #expect(chapters.map(\.wordCount) == [10, 20, 5])
        #expect(chapters.map(\.cumWordsStart) == [0, 10, 30])
        #expect(WordIndex(bookID: "b", chapters: chapters).totalWords == 35)
    }

    @Test func nonLinearChapterExcludedFromTotals() {
        let chapters = WordIndexer.index([
            chapter(0, paragraph(words: 10)),
            chapter(1, paragraph(words: 100), linear: false),
            chapter(2, paragraph(words: 5)),
        ])
        #expect(chapters.map(\.cumWordsStart) == [0, 10, 10])
        #expect(chapters[1].isLinear == false)
        #expect(chapters[1].wordCount == 100)
        #expect(WordIndex(bookID: "b", chapters: chapters).totalWords == 15)
    }

    @Test func fallbackTitle() {
        let chapters = WordIndexer.index([
            chapter(0, "", title: nil),
            chapter(1, "", title: "  "),
            chapter(2, "", title: "Real"),
        ])
        #expect(chapters.map(\.title) == ["Section 1", "Section 2", "Real"])
    }

    @Test func emptyChapter() {
        let c = WordIndexer.index([chapter(0, "")])[0]
        #expect(c.wordCount == 0)
        #expect(c.charCount == 0)
        #expect(c.anchors.isEmpty)
        #expect(c.textHash == sha256Hex(""))
    }

    @Test func anchorsPerBlock() throws {
        let c = WordIndexer.index([chapter(0, paragraph(words: 3) + paragraph(words: 4, from: 3))])[0]
        // "w0 w1 w2 w3 w4 w5 w6"
        #expect(c.charCount == 20)
        #expect(c.anchors == [
            BlockAnchor(blockIndex: 0, progression: 0, charOffset: 0, cumWordOffset: 0),
            BlockAnchor(blockIndex: 1, progression: 9.0 / 20.0, charOffset: 9, cumWordOffset: 3),
        ])
        #expect(c.textHash == sha256Hex("w0 w1 w2 w3 w4 w5 w6"))
    }

    @Test func longBlockGetsExtraAnchors() throws {
        // One block of 1000 words, "w0".."w999": ~4890 characters.
        let c = WordIndexer.index([chapter(0, paragraph(words: 1000) + paragraph(words: 2, from: 1000))])[0]
        let offsets = c.anchors.map(\.charOffset)
        let secondBlock = try #require(offsets.last)
        #expect(offsets.dropLast() == [0, 1500, 3000, 4500])
        #expect(c.anchors.map(\.blockIndex) == Array(0..<c.anchors.count))
        // Offsets and word offsets ascend; word offsets match a direct count of the prefix.
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        let text = TextNormalizer.normalize(xhtml: paragraph(words: 1000) + paragraph(words: 2, from: 1000)).text
        for a in c.anchors {
            // Words that start before the anchor (a word cut by an extra anchor counts as before).
            let startedBefore = text.prefix(a.charOffset).split(separator: " ").count
            #expect(a.cumWordOffset == startedBefore, "anchor \(a.blockIndex)")
            #expect(a.progression == Double(a.charOffset) / Double(c.charCount))
        }
        #expect(c.anchors.last?.cumWordOffset == 1000)
        #expect(secondBlock == text.count - "w1000 w1001".count)
    }

    @Test func performance300kWords() {
        // 25 chapters × 12k words, paragraphs of ~120 words.
        let chapters = (0..<25).map { ch -> IndexInputChapter in
            var xhtml = "<html><head><title>c</title></head><body>"
            for p in 0..<100 {
                xhtml += "<p>" + String(repeating: "lorem ipsum dolor sit amet, consectetur adipiscing <i>elit</i> sed do\n", count: 12)
                xhtml += "&ldquo;Quoted&rdquo; para \(p).</p>"
            }
            xhtml += "</body></html>"
            return chapter(ch, xhtml)
        }
        let clock = ContinuousClock()
        var result: [ChapterIndex] = []
        let elapsed = clock.measure { result = WordIndexer.index(chapters) }
        let total = WordIndex(bookID: "b", chapters: result).totalWords
        #expect(total == 25 * 100 * (12 * 10 + 3))
        #expect(elapsed < .seconds(3), "indexing 300k words took \(elapsed)")
    }
}

// MARK: - WordIndex

@Suite struct WordIndexLookupTests {
    private func sampleIndex() -> WordIndex {
        let chapters = WordIndexer.index([
            chapter(0, paragraph(words: 50) + paragraph(words: 400, from: 50) + paragraph(words: 7, from: 450)),
            chapter(1, paragraph(words: 30), linear: false),
            chapter(2, ""),
            chapter(3, paragraph(words: 3) + paragraph(words: 200, from: 3)),
        ])
        return WordIndex(bookID: "book-1", chapters: chapters)
    }

    @Test func unknownHrefIsNil() {
        let index = sampleIndex()
        #expect(index.wordIdx(href: "nope.xhtml", progression: 0.5) == nil)
        #expect(index.chapterID(href: "nope.xhtml") == nil)
    }

    @Test func chapterIDFormat() {
        let index = sampleIndex()
        #expect(index.chapterID(href: "OEBPS/ch3.xhtml") == "book-1:3")
        #expect(WordIndex.chapterID(bookID: "x", spineIndex: 7) == "x:7")
    }

    @Test func exactValuesAtEnds() {
        let index = sampleIndex()
        #expect(index.totalWords == 457 + 203)
        #expect(index.wordIdx(href: "OEBPS/ch0.xhtml", progression: 0) == 0)
        #expect(index.wordIdx(href: "OEBPS/ch0.xhtml", progression: 1) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch2.xhtml", progression: 0) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch2.xhtml", progression: 1) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: 0) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: 1) == 660)
        // Clamping and non-finite input.
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: -2) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: 7) == 660)
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: .nan) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch3.xhtml", progression: .infinity) == 457)
    }

    @Test func exactValueAtAnchor() {
        let index = sampleIndex()
        let ch0 = index.chapters[0]
        let second = ch0.anchors[1]
        #expect(second.cumWordOffset == 50)
        #expect(index.wordIdx(href: ch0.href, progression: second.progression) == 50)
    }

    @Test func monotonicSweepAcrossLinearChapters() {
        let index = sampleIndex()
        var previous = -1
        for chapter in index.chapters where chapter.isLinear {
            for step in 0...2000 {
                let p = Double(step) / 2000
                let value = index.wordIdx(href: chapter.href, progression: p)!
                #expect(value >= previous, "\(chapter.href) p=\(p): \(value) < \(previous)")
                previous = value
            }
        }
        #expect(previous == index.totalWords)
    }

    @Test func nonLinearChapterSitsAtRunningValue() {
        let index = sampleIndex()
        #expect(index.wordIdx(href: "OEBPS/ch1.xhtml", progression: 0) == 457)
        #expect(index.wordIdx(href: "OEBPS/ch1.xhtml", progression: 1) == 487)
    }

    @Test func noAnchorsInterpolatesWholeChapter() {
        let c = ChapterIndex(spineIndex: 0, href: "a", title: "A", isLinear: true, wordCount: 100,
                             charCount: 500, cumWordsStart: 10, textHash: "", anchors: [])
        let index = WordIndex(bookID: "b", chapters: [c])
        #expect(index.wordIdx(href: "a", progression: 0) == 10)
        #expect(index.wordIdx(href: "a", progression: 0.5) == 60)
        #expect(index.wordIdx(href: "a", progression: 1) == 110)
    }
}
