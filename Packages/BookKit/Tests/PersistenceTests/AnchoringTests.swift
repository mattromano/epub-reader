import Foundation
import GRDB
import Importing
import Testing
@testable import Persistence

// M4 re-anchor on open (SPEC §7, step 3): HighlightAnchoring.reanchor, staleAnchors, applyAnchor.

private let t0 = Timestamp.date(from: "2026-11-22T10:00:00.000Z")!

private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

private func record(quote: String, prefix: String = "", suffix: String = "", charStart: Int? = nil,
                    charEnd: Int? = nil, progression: Double? = nil) -> HighlightRecord {
    HighlightRecord(
        id: "h", bookID: "b", chapterID: nil, spineHref: nil, chapterTitle: nil, quoteExact: quote,
        quotePrefix: prefix, quoteSuffix: suffix, charStart: charStart, charEnd: charEnd, wordIdx: nil,
        wordCount: nil, progression: progression, totalProgression: nil, position: nil, cssSelector: nil,
        partialCFI: nil, domRangeJSON: nil, locatorJSON: "{}", readiumVersion: nil, chapterTextHash: nil,
        anchorStatus: "exact", anchorScore: nil, lastAnchoredAt: nil, color: "yellow", note: "",
        style: "highlight", exportReadwiseAt: nil, createdAt: nil, updatedAt: nil, deletedAt: nil)
}

private func substring(_ text: String, _ outcome: AnchorOutcome) -> String? {
    guard case let .exact(start, end) = outcome else { return nil }
    let chars = Array(text)
    return String(chars[start..<end])
}

@Suite struct ReanchorTests {
    private let original = "It was a dark night. The stone sank into the river. Morning came."

    @Test func exactHitAtStoredOffsets() {
        let h = record(quote: "The stone sank", prefix: "dark night. ", suffix: " into the", charStart: 21, charEnd: 35)
        let outcome = HighlightAnchoring.reanchor(h, in: original)
        #expect(outcome == .exact(charStart: 21, charEnd: 35))
        #expect(substring(original, outcome) == "The stone sank")
    }

    @Test func movedQuoteFollowsInsertedText() {
        let inserted = "A new foreword paragraph appears here. "
        let edited = inserted + original
        let h = record(quote: "The stone sank", prefix: "dark night. ", suffix: " into the", charStart: 21, charEnd: 35)
        let outcome = HighlightAnchoring.reanchor(h, in: edited)
        #expect(outcome == .exact(charStart: 21 + inserted.count, charEnd: 35 + inserted.count))
        #expect(substring(edited, outcome) == "The stone sank")
    }

    @Test func ambiguousQuoteResolvedByPrefixAndSuffix() {
        let text = "The cat sat on the mat. Then the cat ran to the door. Later the cat slept."
        // Stored offsets point at the first "the cat" (an older edition); the context says the second.
        let h = record(quote: "the cat", prefix: "Then ", suffix: " ran to", charStart: 15, charEnd: 22)
        let outcome = HighlightAnchoring.reanchor(h, in: text)
        let expectedStart = Array(text).indices.first { String(Array(text)[$0..<($0 + 12)]) == "the cat ran " }!
        #expect(outcome == .exact(charStart: expectedStart, charEnd: expectedStart + 7))

        let third = record(quote: "the cat", prefix: "Later ", suffix: " slept")
        guard case let .exact(start, _) = HighlightAnchoring.reanchor(third, in: text) else {
            Issue.record("expected exact")
            return
        }
        #expect(String(Array(text)[(start - 6)..<start]) == "Later ")
    }

    @Test func ambiguousQuoteWithoutContextUsesPositionHint() {
        let text = "echo one. echo two. echo three."
        let firstEcho = 0
        let lastEcho = Array(text).count - "echo three.".count
        let nearEnd = record(quote: "echo", charStart: lastEcho)
        #expect(HighlightAnchoring.reanchor(nearEnd, in: text) == .exact(charStart: lastEcho, charEnd: lastEcho + 4))
        let byProgression = record(quote: "echo", progression: 0.95)
        #expect(HighlightAnchoring.reanchor(byProgression, in: text) == .exact(charStart: lastEcho, charEnd: lastEcho + 4))
        let noHint = record(quote: "echo")
        #expect(HighlightAnchoring.reanchor(noHint, in: text) == .exact(charStart: firstEcho, charEnd: firstEcho + 4))
    }

    @Test func missingQuoteIsOrphaned() {
        let h = record(quote: "a passage that was cut", prefix: "dark night. ", charStart: 21, charEnd: 43)
        #expect(HighlightAnchoring.reanchor(h, in: original) == .orphaned)
        #expect(HighlightAnchoring.reanchor(record(quote: ""), in: original) == .orphaned)
        #expect(HighlightAnchoring.reanchor(record(quote: "stone", charStart: 3), in: "") == .orphaned)
    }

    @Test func offsetsAreCharacterOffsets() {
        let text = "Café 👩‍👩‍👧 then the stone sank."
        let h = record(quote: "stone sank")
        let outcome = HighlightAnchoring.reanchor(h, in: text)
        #expect(substring(text, outcome) == "stone sank")
    }
}

// MARK: - staleAnchors / applyAnchor

private struct Fixture {
    let db: AppDatabase
    let book: String
    let otherBook: String
}

private func makeFixture() async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    func insert(_ title: String) async throws -> String {
        guard case .inserted(let b) = try await db.importBook(
            NewBook(contentHash: title, title: title, authors: "A", fileRelpath: "Books/\(title).epub",
                    fileSizeBytes: 1), now: t0) else { Issue.record("expected insert"); return "" }
        return b.id
    }
    let book = try await insert("Book")
    let other = try await insert("Other")
    try await db.writer.write { db in
        try db.execute(sql: """
            INSERT INTO dim_chapter (chapter_id, book_id, spine_index, href, title, text_hash) VALUES
                (:b || ':1', :b, 1, 'OEBPS/ch1.xhtml', 'One', 'new-1'),
                (:b || ':2', :b, 2, 'OEBPS/ch2.xhtml', 'Two', 'same-2'),
                (:b || ':3', :b, 3, 'OEBPS/ch3.xhtml', 'Three', NULL),
                (:o || ':1', :o, 1, 'OEBPS/ch1.xhtml', 'One', 'other-new');
            """, arguments: ["b": book, "o": other])
    }
    return Fixture(db: db, book: book, otherBook: other)
}

@discardableResult
private func highlight(_ f: Fixture, book: String? = nil, chapter: String, hash: String?, total: Double,
                       charStart: Int? = 10, charEnd: Int? = 20) async throws -> String {
    let bookID = book ?? f.book
    return try await f.db.saveHighlight(
        NewHighlight(bookID: bookID, chapterID: "\(bookID):\(chapter)", quoteExact: "quote",
                     charStart: charStart, charEnd: charEnd, totalProgression: total, locatorJSON: "{}",
                     chapterTextHash: hash),
        now: at(total)
    ).id
}

private func fetch(_ db: AppDatabase, _ id: String) async throws -> HighlightRecord {
    try await db.reader.read { db in
        try #require(try HighlightRecord.fetchOne(db, key: id))
    }
}

@Suite struct StaleAnchorTests {
    @Test func returnsOnlyHashMismatches() async throws {
        let f = try await makeFixture()
        let stale1 = try await highlight(f, chapter: "1", hash: "old-1", total: 0.3)
        let stale2 = try await highlight(f, chapter: "1", hash: "older-1", total: 0.1)
        try await highlight(f, chapter: "2", hash: "same-2", total: 0.4)          // equal hash
        try await highlight(f, chapter: "1", hash: nil, total: 0.5)               // no stored hash
        try await highlight(f, chapter: "3", hash: "anything", total: 0.6)        // chapter hash NULL
        try await highlight(f, chapter: "9", hash: "old-9", total: 0.7)           // chapter not indexed
        let deleted = try await highlight(f, chapter: "1", hash: "old-1", total: 0.8)
        try await f.db.softDeleteHighlight(id: deleted, now: at(100))
        try await highlight(f, book: f.otherBook, chapter: "1", hash: "other-old", total: 0.2) // other book

        let stale = try await f.db.staleAnchors(bookID: f.book)
        #expect(stale.map(\.highlight.id) == [stale2, stale1])
        #expect(stale.map(\.chapterHref) == ["OEBPS/ch1.xhtml", "OEBPS/ch1.xhtml"])
        #expect(stale.map(\.currentTextHash) == ["new-1", "new-1"])
        #expect(stale.first?.highlight.chapterTextHash == "older-1")

        let other = try await f.db.staleAnchors(bookID: f.otherBook)
        #expect(other.count == 1)
        #expect(other.first?.currentTextHash == "other-new")
        #expect(try await f.db.staleAnchors(bookID: "missing").isEmpty)
    }

    @Test func applyExactUpdatesAnchorAndClearsStaleness() async throws {
        let f = try await makeFixture()
        let id = try await highlight(f, chapter: "1", hash: "old-1", total: 0.3)
        try await f.db.writer.write { try $0.execute(sql: "UPDATE fact_highlight SET anchor_score = 0.4") }
        let before = try await fetch(f.db, id)

        try await f.db.applyAnchor(id: id, outcome: .exact(charStart: 42, charEnd: 57), textHash: "new-1", now: at(500))
        let after = try await fetch(f.db, id)
        #expect(after.anchorStatus == "exact")
        #expect(after.charStart == 42 && after.charEnd == 57)
        #expect(after.chapterTextHash == "new-1")
        #expect(after.anchorScore == nil)
        #expect(after.lastAnchoredAt == Timestamp.string(from: at(500)))
        #expect(after.updatedAt == Timestamp.string(from: at(500)))
        // Nothing else changes.
        #expect(after.createdAt == before.createdAt)
        #expect(after.quoteExact == before.quoteExact)
        #expect(after.locatorJSON == before.locatorJSON)
        #expect(after.deletedAt == nil)

        #expect(try await f.db.staleAnchors(bookID: f.book).isEmpty)
    }

    @Test func applyOrphanKeepsOffsetsAndStaysVisible() async throws {
        let f = try await makeFixture()
        let id = try await highlight(f, chapter: "1", hash: "old-1", total: 0.3, charStart: 10, charEnd: 20)
        try await f.db.applyAnchor(id: id, outcome: .orphaned, textHash: "new-1", now: at(500))

        let after = try await fetch(f.db, id)
        #expect(after.anchorStatus == "orphaned")
        #expect(after.charStart == 10 && after.charEnd == 20)
        #expect(after.chapterTextHash == "new-1")
        #expect(after.lastAnchoredAt == Timestamp.string(from: at(500)))
        #expect(after.updatedAt == Timestamp.string(from: at(500)))
        #expect(after.deletedAt == nil)
        #expect(try await f.db.staleAnchors(bookID: f.book).isEmpty)

        let items = try await f.db.reader.read { try QuoteRequests.quotes(QuoteFilter()).fetchAll($0) }
        #expect(items.map(\.id) == [id])
        #expect(items.first?.isOrphaned == true)
    }

    @Test func applyOnDeletedRowIsNoOp() async throws {
        let f = try await makeFixture()
        let id = try await highlight(f, chapter: "1", hash: "old-1", total: 0.3)
        try await f.db.softDeleteHighlight(id: id, now: at(100))
        let before = try await fetch(f.db, id)
        try await f.db.applyAnchor(id: id, outcome: .exact(charStart: 1, charEnd: 2), textHash: "new-1", now: at(500))
        #expect(try await fetch(f.db, id) == before)
    }

    @Test func reanchorThenApplyEndToEnd() async throws {
        let f = try await makeFixture()
        let oldText = "Intro. The stone sank into the river. End."
        let newText = "A new preface. Intro. The stone sank into the river. End."
        let start = Array(oldText).count - "The stone sank into the river. End.".count
        let id = try await f.db.saveHighlight(
            NewHighlight(bookID: f.book, chapterID: "\(f.book):1", quoteExact: "The stone sank",
                         quotePrefix: "Intro. ", quoteSuffix: " into", charStart: start, charEnd: start + 14,
                         locatorJSON: "{}", chapterTextHash: TextNormalizer.textHash(oldText)),
            now: at(1)).id
        try await f.db.writer.write { db in
            try db.execute(sql: "UPDATE dim_chapter SET text_hash = ? WHERE chapter_id = ?",
                           arguments: [TextNormalizer.textHash(newText), "\(f.book):1"])
        }

        for anchor in try await f.db.staleAnchors(bookID: f.book) {
            let outcome = HighlightAnchoring.reanchor(anchor.highlight, in: newText)
            try await f.db.applyAnchor(id: anchor.highlight.id, outcome: outcome,
                                       textHash: anchor.currentTextHash, now: at(9))
        }
        let after = try await fetch(f.db, id)
        let shift = "A new preface. ".count
        #expect(after.charStart == start + shift && after.charEnd == start + shift + 14)
        #expect(after.chapterTextHash == TextNormalizer.textHash(newText))
        #expect(try await f.db.staleAnchors(bookID: f.book).isEmpty)
    }
}
