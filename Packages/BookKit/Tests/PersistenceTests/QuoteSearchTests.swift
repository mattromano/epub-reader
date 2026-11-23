import Foundation
import GRDB
import Testing
@testable import Persistence

// M4: fts_highlight (v5), QuoteRequests filters/sorts, and the PLAN M4 search acceptance check.

private let t0 = Timestamp.date(from: "2026-11-22T10:00:00.000Z")!

private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

private func addBook(_ db: AppDatabase, title: String, authors: String = "Ada Lovelace",
                     hash: String? = nil) async throws -> String {
    let result = try await db.importBook(
        NewBook(contentHash: hash ?? "hash-\(title)", title: title, authors: authors,
                fileRelpath: "Books/\(title).epub", fileSizeBytes: 1),
        now: t0)
    guard case .inserted(let record) = result else {
        Issue.record("expected insert")
        return ""
    }
    return record.id
}

@discardableResult
private func addHighlight(_ db: AppDatabase, book: String, quote: String, note: String = "",
                          color: HighlightColor = .yellow, total: Double? = nil,
                          at offset: Double = 0) async throws -> String {
    try await db.saveHighlight(
        NewHighlight(bookID: book, chapterTitle: "Chapter", quoteExact: quote, totalProgression: total,
                     locatorJSON: "{}", color: color, note: note),
        now: at(offset)
    ).id
}

private func quotes(_ db: AppDatabase, _ filter: QuoteFilter = QuoteFilter()) async throws -> [QuoteItem] {
    try await db.reader.read { try QuoteRequests.quotes(filter).fetchAll($0) }
}

private func ids(_ db: AppDatabase, search: String) async throws -> Set<String> {
    Set(try await quotes(db, QuoteFilter(search: search)).map(\.id))
}

private func ftsRowCount(_ db: AppDatabase) async throws -> Int {
    try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fts_highlight") ?? 0 }
}

private func exec(_ db: AppDatabase, _ sql: String, _ arguments: StatementArguments = []) async throws {
    try await db.writer.write { try $0.execute(sql: sql, arguments: arguments) }
}

// MARK: - Migration

@Suite struct HighlightSearchMigrationTests {
    @Test func v5CreatesFTSTableAndTriggers() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            #expect(try db.tableExists("fts_highlight"))
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(fts_highlight)").map { $0["name"] as String }
            #expect(columns == ["highlight_id", "quote_exact", "note", "title", "authors"])
            let triggers = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name
                """)
            #expect(Set(triggers).isSuperset(of: [
                "fts_highlight_after_insert", "fts_highlight_after_update", "fts_highlight_after_delete",
                "fts_highlight_after_book_update",
            ]))
        }
    }

    @Test func backfillIndexesHighlightsSavedBeforeV5() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4_highlights")
        try queue.write { db in
            #expect(try !db.tableExists("fts_highlight"))
            try db.execute(sql: """
                INSERT INTO dim_book (book_id, content_hash, title, authors)
                VALUES ('b1', 'h1', 'The Quiet Harbor', 'Ada Lovelace');
                INSERT INTO fact_highlight (highlight_id, book_id, quote_exact, note, created_at)
                VALUES ('live', 'b1', 'a stone in the river', 'mossy', '2026-11-22T10:00:00.000Z'),
                       ('gone', 'b1', 'a stone in the lake', '', '2026-11-22T10:00:01.000Z'),
                       ('nullnote', 'b1', 'the lighthouse keeper', NULL, '2026-11-22T10:00:02.000Z'),
                       ('orphanbook', 'missing', 'stone without a book', '', '2026-11-22T10:00:03.000Z');
                UPDATE fact_highlight SET deleted_at = '2026-11-22T11:00:00.000Z' WHERE highlight_id = 'gone';
                """)
        }
        let db = try AppDatabase(queue)
        try queue.read { db in
            let indexed = try String.fetchAll(db, sql: "SELECT highlight_id FROM fts_highlight ORDER BY highlight_id")
            #expect(indexed == ["live", "nullnote", "orphanbook"])
            let matches = try String.fetchAll(db, sql: """
                SELECT highlight_id FROM fts_highlight WHERE fts_highlight MATCH 'harbor' ORDER BY highlight_id
                """)
            #expect(matches == ["live", "nullnote"])
        }
        let found = try queue.read { try QuoteRequests.quotes(QuoteFilter(search: "mossy")).fetchAll($0) }
        #expect(found.map(\.id) == ["live"])
        _ = db
    }
}

// MARK: - FTS sync

@Suite struct HighlightSearchTests {
    @Test func patternQuotesEachWordAsPrefix() {
        #expect(FTSQuery.pattern(from: "ston") == "\"ston\"*")
        #expect(FTSQuery.pattern(from: "  stone   river ") == "\"stone\"* \"river\"*")
        #expect(FTSQuery.pattern(from: "a\"b*c") == "\"a\"* \"b\"* \"c\"*")
        #expect(FTSQuery.pattern(from: "café") == "\"café\"*")
        #expect(FTSQuery.pattern(from: "") == nil)
        #expect(FTSQuery.pattern(from: " \n\t ") == nil)
        #expect(FTSQuery.pattern(from: "\"*-()") == nil)
    }

    @Test func findsByQuoteNoteTitleAndAuthor() async throws {
        let db = try AppDatabase.inMemory()
        let harbor = try await addBook(db, title: "The Quiet Harbor", authors: "Ada Lovelace")
        let ember = try await addBook(db, title: "Ember Days", authors: "Charlotte Brontë")
        let river = try await addHighlight(db, book: harbor, quote: "A stone in the river")
        let coffee = try await addHighlight(db, book: harbor, quote: "Coffee downstairs", note: "remember the espresso")
        let fire = try await addHighlight(db, book: ember, quote: "Fire and ash")

        #expect(try await ids(db, search: "river") == [river])
        #expect(try await ids(db, search: "espresso") == [coffee])
        #expect(try await ids(db, search: "harbor") == [river, coffee])
        #expect(try await ids(db, search: "lovelace") == [river, coffee])
        #expect(try await ids(db, search: "Ember") == [fire])
        // Every word must match (AND), in any column.
        #expect(try await ids(db, search: "stone harbor") == [river])
        #expect(try await ids(db, search: "stone espresso") == [])
        // Case-insensitive.
        #expect(try await ids(db, search: "RIVER") == [river])
    }

    @Test func prefixSearch() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let stone = try await addHighlight(db, book: book, quote: "A stone in the river")
        let story = try await addHighlight(db, book: book, quote: "Once upon a story")
        _ = try await addHighlight(db, book: book, quote: "Moonstone light")

        #expect(try await ids(db, search: "ston") == [stone])
        #expect(try await ids(db, search: "st") == [stone, story])
        #expect(try await ids(db, search: "s") == [stone, story])
        #expect(try await ids(db, search: "sto riv") == [stone])
    }

    @Test func diacriticsAreIgnoredBothWays() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Ember Days", authors: "Charlotte Brontë")
        let cafe = try await addHighlight(db, book: book, quote: "We met at the café")
        let plain = try await addHighlight(db, book: book, quote: "A naive resume")

        #expect(try await ids(db, search: "cafe") == [cafe])
        #expect(try await ids(db, search: "CAFÉ") == [cafe])
        #expect(try await ids(db, search: "cafe\u{301}") == [cafe]) // decomposed é
        #expect(try await ids(db, search: "naïve résumé") == [plain])
        #expect(try await ids(db, search: "bronte") == [cafe, plain])
    }

    @Test func updatingNoteReindexes() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let id = try await addHighlight(db, book: book, quote: "quote", note: "espresso")
        #expect(try await ids(db, search: "espresso") == [id])

        try await db.updateHighlight(id: id, note: "lighthouse", now: at(10))
        #expect(try await ids(db, search: "espresso") == [])
        #expect(try await ids(db, search: "lighthouse") == [id])
        #expect(try await ftsRowCount(db) == 1)

        // Color changes keep the row searchable (update trigger re-inserts it once).
        try await db.updateHighlight(id: id, color: .pink, now: at(20))
        #expect(try await ids(db, search: "lighthouse") == [id])
        #expect(try await ftsRowCount(db) == 1)
    }

    @Test func softDeleteRemovesFromResultsAndIndex() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let gone = try await addHighlight(db, book: book, quote: "stone river")
        let kept = try await addHighlight(db, book: book, quote: "stone lake")
        try await db.softDeleteHighlight(id: gone, now: at(10))

        #expect(try await ids(db, search: "stone") == [kept])
        #expect(try await ids(db, search: "river") == [])
        #expect(try await ftsRowCount(db) == 1)
        #expect(try await quotes(db).map(\.id) == [kept])
    }

    @Test func hardDeleteRemovesIndexRow() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let id = try await addHighlight(db, book: book, quote: "stone river")
        try await exec(db, "DELETE FROM fact_highlight WHERE highlight_id = ?", [id])
        #expect(try await ftsRowCount(db) == 0)
    }

    @Test func insertingDeletedHighlightIsNotIndexed() async throws {
        let db = try AppDatabase.inMemory()
        try await exec(db, """
            INSERT INTO fact_highlight (highlight_id, book_id, quote_exact, deleted_at)
            VALUES ('h', 'b', 'stone', '2026-11-22T10:00:00.000Z')
            """)
        #expect(try await ftsRowCount(db) == 0)
    }

    @Test func renamingBookUpdatesTitleAndAuthorMatches() async throws {
        let db = try AppDatabase.inMemory()
        let harbor = try await addBook(db, title: "The Quiet Harbor", authors: "Ada Lovelace")
        let other = try await addBook(db, title: "Ember Days", authors: "Someone Else")
        let a = try await addHighlight(db, book: harbor, quote: "one")
        let deleted = try await addHighlight(db, book: harbor, quote: "two")
        let b = try await addHighlight(db, book: other, quote: "three")
        try await db.softDeleteHighlight(id: deleted, now: at(5))

        try await exec(db, "UPDATE dim_book SET title = 'Northern Lights' WHERE book_id = ?", [harbor])
        #expect(try await ids(db, search: "harbor") == [])
        #expect(try await ids(db, search: "northern") == [a])
        #expect(try await ids(db, search: "lovelace") == [a])
        #expect(try await ids(db, search: "ember") == [b])

        try await exec(db, "UPDATE dim_book SET authors = 'Grace Hopper' WHERE book_id = ?", [harbor])
        #expect(try await ids(db, search: "lovelace") == [])
        #expect(try await ids(db, search: "hopper") == [a])
        // Soft-deleted highlights stay out of the index after a rename; other books are untouched.
        #expect(try await ftsRowCount(db) == 2)
        #expect(try await ids(db, search: "two") == [])
    }

    @Test func otherBookUpdatesLeaveIndexAlone() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Harbor")
        let id = try await addHighlight(db, book: book, quote: "one")
        try await db.updateResumePoint(bookID: book, locatorJSON: "{}", totalProgression: 0.5, now: at(5))
        try await db.markOpened(bookID: book, now: at(6))
        #expect(try await ids(db, search: "harbor") == [id])
        #expect(try await ftsRowCount(db) == 1)
    }

    @Test(arguments: [
        "\"", "\"unbalanced", "\"\"", "*", "**", "AND", "OR", "NOT", "-", "river -stone", "NEAR(",
        "NEAR(stone river)", "stone*", "^stone", "title:river", ":", "(", ")", "{a b}", "+", "'", "stone AND",
        "a OR", "\\", "%", "_", "stone\"river", "🙂", "a'b",
    ])
    func operatorCharactersDoNotThrow(input: String) async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        _ = try await addHighlight(db, book: book, quote: "Fire and a stone in the river")
        _ = try await quotes(db, QuoteFilter(search: input))
    }

    @Test func operatorWordsAreSearchedAsPlainText() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let fire = try await addHighlight(db, book: book, quote: "Fire and ash")
        let stone = try await addHighlight(db, book: book, quote: "A stone in the river")

        #expect(try await ids(db, search: "AND") == [fire])
        #expect(try await ids(db, search: "river -stone") == [stone])
        #expect(try await ids(db, search: "NEAR(stone river)") == []) // "near" is a word to match, not an operator
        #expect(try await ids(db, search: "\"stone") == [stone])
        #expect(try await ids(db, search: "quote_exact:stone") == [])
    }

    @Test(arguments: ["", "   ", "\n\t", "\"*()"])
    func emptySearchReturnsEverything(input: String) async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let a = try await addHighlight(db, book: book, quote: "one", at: 1)
        let b = try await addHighlight(db, book: book, quote: "two", at: 2)
        #expect(try await quotes(db, QuoteFilter(search: input)).map(\.id) == [b, a])
    }

    @Test func highlightIDIsNotSearchable() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Book")
        let id = try await addHighlight(db, book: book, quote: "one")
        let fragment = String(id.prefix(8))
        #expect(try await ids(db, search: fragment) == [])
    }
}

// MARK: - Filters and sorts

@Suite struct QuoteFilterTests {
    @Test func bookFilter() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await addBook(db, title: "A")
        let b = try await addBook(db, title: "B")
        let inA = try await addHighlight(db, book: a, quote: "one")
        _ = try await addHighlight(db, book: b, quote: "two")
        #expect(try await quotes(db, QuoteFilter(bookID: a)).map(\.id) == [inA])
        #expect(try await quotes(db, QuoteFilter(bookID: "nope")).isEmpty)
    }

    @Test func colorFilterTreatsNullAndUnknownColorsAsYellow() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let yellow = try await addHighlight(db, book: book, quote: "y", color: .yellow, at: 1)
        let green = try await addHighlight(db, book: book, quote: "g", color: .green, at: 2)
        let blue = try await addHighlight(db, book: book, quote: "b", color: .blue, at: 3)
        let nullColor = try await addHighlight(db, book: book, quote: "n", color: .pink, at: 4)
        let unknown = try await addHighlight(db, book: book, quote: "u", color: .pink, at: 5)
        let empty = try await addHighlight(db, book: book, quote: "e", color: .pink, at: 6)
        try await exec(db, "UPDATE fact_highlight SET color = NULL WHERE highlight_id = ?", [nullColor])
        try await exec(db, "UPDATE fact_highlight SET color = 'orange' WHERE highlight_id = ?", [unknown])
        try await exec(db, "UPDATE fact_highlight SET color = '' WHERE highlight_id = ?", [empty])

        let all = try await quotes(db)
        // The card renders these as yellow, so the yellow chip must include them.
        for item in all where [nullColor, unknown, empty].contains(item.id) {
            #expect(item.highlight.highlightColor == .yellow)
        }

        let yellows = try await quotes(db, QuoteFilter(colors: [.yellow]))
        #expect(Set(yellows.map(\.id)) == [yellow, nullColor, unknown, empty])
        let yellowOrBlue = try await quotes(db, QuoteFilter(colors: [.yellow, .blue]))
        #expect(Set(yellowOrBlue.map(\.id)) == [yellow, blue, nullColor, unknown, empty])
        #expect(try await quotes(db, QuoteFilter(colors: [.green])).map(\.id) == [green])
        #expect(try await quotes(db, QuoteFilter(colors: [.purple])).isEmpty)
        #expect(try await quotes(db, QuoteFilter(colors: [])).count == 6)
    }

    @Test func tagFilterIgnoresDeletedBridgesAndTags() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let h1 = try await addHighlight(db, book: book, quote: "one", at: 1)
        let h2 = try await addHighlight(db, book: book, quote: "two", at: 2)
        _ = try await addHighlight(db, book: book, quote: "three", at: 3)
        let work = try #require(try await db.addTag(name: "Work", toHighlight: h1, now: at(10)))
        _ = try await db.addTag(name: "work", toHighlight: h2, now: at(11))

        #expect(Set(try await quotes(db, QuoteFilter(tagID: work.id)).map(\.id)) == [h1, h2])

        try await db.removeTag(tagID: work.id, fromHighlight: h2, now: at(12))
        #expect(try await quotes(db, QuoteFilter(tagID: work.id)).map(\.id) == [h1])

        try await exec(db, "UPDATE dim_tag SET deleted_at = ? WHERE tag_id = ?",
                       [Timestamp.string(from: at(13)), work.id])
        #expect(try await quotes(db, QuoteFilter(tagID: work.id)).isEmpty)
        #expect(try await quotes(db).first { $0.id == h1 }?.tags == [])
    }

    @Test func deletedBooksAreExcluded() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await addBook(db, title: "Apple")
        let b = try await addBook(db, title: "Banana")
        let inA = try await addHighlight(db, book: a, quote: "stone")
        _ = try await addHighlight(db, book: b, quote: "stone")
        try await db.softDeleteBook(id: b, now: at(5))

        #expect(try await quotes(db).map(\.id) == [inA])
        #expect(try await ids(db, search: "stone") == [inA])
        #expect(try await quotes(db, QuoteFilter(bookID: b)).isEmpty)
    }

    @Test func highlightWithoutBookRowIsExcluded() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await addHighlight(db, book: "missing", quote: "stone")
        #expect(try await quotes(db).isEmpty)
        #expect(try await ids(db, search: "stone") == [])
    }

    @Test func searchCombinesWithFilters() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await addBook(db, title: "Harbor")
        let b = try await addBook(db, title: "Ember")
        let target = try await addHighlight(db, book: a, quote: "stone river", color: .green, at: 1)
        let wrongColor = try await addHighlight(db, book: a, quote: "stone lake", color: .blue, at: 2)
        let wrongBook = try await addHighlight(db, book: b, quote: "stone hill", color: .green, at: 3)
        let noTag = try await addHighlight(db, book: a, quote: "stone field", color: .green, at: 4)
        let tag = try #require(try await db.addTag(name: "keep", toHighlight: target, now: at(10)))
        for id in [wrongColor, wrongBook] { _ = try await db.addTag(name: "keep", toHighlight: id, now: at(11)) }

        let filter = QuoteFilter(search: "ston", bookID: a, colors: [.green], tagID: tag.id)
        #expect(try await quotes(db, filter).map(\.id) == [target])

        var loose = filter
        loose.tagID = nil
        #expect(try await quotes(db, loose).map(\.id) == [noTag, target])
        loose.bookID = nil
        #expect(try await quotes(db, loose).map(\.id) == [noTag, wrongBook, target])
        loose.search = "river"
        #expect(try await quotes(db, loose).map(\.id) == [target])
    }

    @Test func recentSortIsNewestFirstWithIDTiebreak() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await addBook(db, title: "A")
        let b = try await addBook(db, title: "B")
        let first = try await addHighlight(db, book: a, quote: "1", at: 1)
        let third = try await addHighlight(db, book: b, quote: "3", at: 3)
        let second = try await addHighlight(db, book: a, quote: "2", at: 2)
        let tieX = try await addHighlight(db, book: b, quote: "x", at: 4)
        let tieY = try await addHighlight(db, book: a, quote: "y", at: 4)

        let order = try await quotes(db, QuoteFilter(sort: .recent)).map(\.id)
        #expect(order == [tieX, tieY].sorted() + [third, second, first])
    }

    @Test func bookSortGroupsByTitleThenReadingOrder() async throws {
        let db = try AppDatabase.inMemory()
        let cherry = try await addBook(db, title: "cherry")
        let apple = try await addBook(db, title: "Apple")
        let banana = try await addBook(db, title: "banana")
        let c1 = try await addHighlight(db, book: cherry, quote: "c1", total: 0.1, at: 1)
        let a2 = try await addHighlight(db, book: apple, quote: "a2", total: 0.9, at: 2)
        let a1 = try await addHighlight(db, book: apple, quote: "a1", total: 0.2, at: 3)
        let b1 = try await addHighlight(db, book: banana, quote: "b1", total: 0.5, at: 4)
        let a1Later = try await addHighlight(db, book: apple, quote: "a1 later", total: 0.2, at: 5)

        let items = try await quotes(db, QuoteFilter(sort: .book))
        #expect(items.map(\.id) == [a1, a1Later, a2, b1, c1])
        #expect(items.map(\.bookTitle) == ["Apple", "Apple", "Apple", "banana", "cherry"])
    }

    @Test func bookSortKeepsSameTitledBooksApart() async throws {
        let db = try AppDatabase.inMemory()
        let x = try await addBook(db, title: "Same", hash: "x")
        let y = try await addBook(db, title: "Same", hash: "y")
        let x1 = try await addHighlight(db, book: x, quote: "x1", total: 0.1)
        let y1 = try await addHighlight(db, book: y, quote: "y1", total: 0.2)
        let x2 = try await addHighlight(db, book: x, quote: "x2", total: 0.3)
        let order = try await quotes(db, QuoteFilter(sort: .book)).map(\.id)
        let expected = x < y ? [x1, x2, y1] : [y1, x1, x2]
        #expect(order == expected)
    }

    @Test func itemCarriesBookAndOrphanState() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "Harbor", authors: "Ada Lovelace")
        let id = try await addHighlight(db, book: book, quote: "one", note: "n")
        let item = try #require(try await quotes(db).first)
        #expect(item.id == id)
        #expect(item.bookTitle == "Harbor")
        #expect(item.bookAuthors == "Ada Lovelace")
        #expect(item.highlight.quoteExact == "one")
        #expect(item.highlight.note == "n")
        #expect(item.tags == [])
        #expect(!item.isOrphaned)

        try await exec(db, "UPDATE fact_highlight SET anchor_status = 'orphaned'")
        #expect(try await quotes(db).first?.isOrphaned == true)
    }
}

// MARK: - Tags on QuoteItem

@Suite struct QuoteItemTagTests {
    @Test func tagsSortedCaseInsensitivelyWithoutDeleted() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let id = try await addHighlight(db, book: book, quote: "one")
        for name in ["gamma", "Alpha", "beta", "Removed", "Deleted tag"] {
            _ = try await db.addTag(name: name, toHighlight: id, now: at(1))
        }
        let removed = try await db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT tag_id FROM dim_tag WHERE name = 'Removed'")
        }
        try await db.removeTag(tagID: try #require(removed), fromHighlight: id, now: at(2))
        try await exec(db, "UPDATE dim_tag SET deleted_at = ? WHERE name = 'Deleted tag'",
                       [Timestamp.string(from: at(3))])

        #expect(try await quotes(db).first?.tags == ["Alpha", "beta", "gamma"])
    }

    @Test func duplicateBridgeRowsDoNotDuplicateTags() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let id = try await addHighlight(db, book: book, quote: "one")
        let tag = try #require(try await db.addTag(name: "Work", toHighlight: id, now: at(1)))
        // Sync can deliver the same (highlight, tag) pair from two devices.
        try await exec(db, """
            INSERT INTO bridge_highlight_tag (bridge_id, highlight_id, tag_id, created_at, updated_at)
            VALUES ('dup', ?, ?, ?, ?)
            """, [id, tag.id, Timestamp.string(from: at(2)), Timestamp.string(from: at(2))])
        #expect(try await quotes(db).first?.tags == ["Work"])
        #expect(try await quotes(db, QuoteFilter(tagID: tag.id)).map(\.id) == [id])
    }

    @Test func sameNamedTagsFromTwoDevicesShowOnce() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let id = try await addHighlight(db, book: book, quote: "one")
        _ = try await db.addTag(name: "Work", toHighlight: id, now: at(1))
        _ = try await db.addTag(name: "Zed", toHighlight: id, now: at(1))
        // A second dim_tag row with the same name (case differs), as sync from another device can create.
        try await exec(db, """
            INSERT INTO dim_tag (tag_id, name, created_at, updated_at) VALUES ('t2', 'work', ?, ?);
            INSERT INTO bridge_highlight_tag (bridge_id, highlight_id, tag_id, created_at, updated_at)
            VALUES ('b2', ?, 't2', ?, ?);
            """, [Timestamp.string(from: at(2)), Timestamp.string(from: at(2)), id,
                  Timestamp.string(from: at(2)), Timestamp.string(from: at(2))])
        let tags = try #require(try await quotes(db).first?.tags)
        #expect(tags.count == 2)
        #expect(tags.map { $0.lowercased() } == ["work", "zed"])
    }

    @Test func tagsAreScopedToTheirHighlight() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, title: "A")
        let a = try await addHighlight(db, book: book, quote: "a", at: 1)
        let b = try await addHighlight(db, book: book, quote: "b", at: 2)
        _ = try await db.addTag(name: "only-a", toHighlight: a, now: at(3))
        _ = try await db.addTag(name: "shared", toHighlight: a, now: at(3))
        _ = try await db.addTag(name: "shared", toHighlight: b, now: at(3))
        let items = Dictionary(uniqueKeysWithValues: try await quotes(db).map { ($0.id, $0.tags) })
        #expect(items[a] == ["only-a", "shared"])
        #expect(items[b] == ["shared"])
    }
}

// MARK: - booksWithHighlights

@Suite struct BooksWithHighlightsTests {
    @Test func onlyLiveBooksWithLiveHighlightsByTitle() async throws {
        let db = try AppDatabase.inMemory()
        let cherry = try await addBook(db, title: "cherry")
        let apple = try await addBook(db, title: "Apple")
        let deletedBook = try await addBook(db, title: "Deleted")
        let noHighlights = try await addBook(db, title: "Empty")
        let onlyDeleted = try await addBook(db, title: "Only deleted")
        _ = noHighlights
        _ = try await addHighlight(db, book: cherry, quote: "c")
        _ = try await addHighlight(db, book: apple, quote: "a1")
        _ = try await addHighlight(db, book: apple, quote: "a2")
        _ = try await addHighlight(db, book: deletedBook, quote: "d")
        let gone = try await addHighlight(db, book: onlyDeleted, quote: "o")
        try await db.softDeleteBook(id: deletedBook, now: at(5))
        try await db.softDeleteHighlight(id: gone, now: at(5))

        let books = try await db.reader.read { try QuoteRequests.booksWithHighlights().fetchAll($0) }
        #expect(books.map(\.id) == [apple, cherry])
    }
}

// MARK: - PLAN M4 acceptance: search 1,000 highlights in under 100 ms

/// Deterministic seed: `count` highlights spread over `books` books, with a common word in every
/// quote and `rareWord` planted in every `rareEvery`-th one. Returns the ids that contain `rareWord`.
@discardableResult
private func seedHighlights(_ db: AppDatabase, count: Int, books: Int, rareWord: String, rareEvery: Int) async throws -> Set<String> {
    let vocabulary = ["harbor", "lantern", "meadow", "copper", "willow", "orchard", "thunder", "velvet",
                      "glacier", "saffron", "ember", "quarry", "nimbus", "tundra", "marble", "juniper"]
    var bookIDs: [String] = []
    for index in 0..<books {
        bookIDs.append(try await addBook(db, title: "Seed Book \(index)", authors: "Author \(index)",
                                         hash: "seed-\(index)"))
    }
    let seededBooks = bookIDs
    return try await db.writer.write { db in
        var rare = Set<String>()
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        for index in 0..<count {
            var words = (0..<24).map { _ in vocabulary[next() % vocabulary.count] }
            words.append("common")
            if index % rareEvery == 0 { words.insert(rareWord, at: next() % words.count) }
            let id = UUID().uuidString
            if index % rareEvery == 0 { rare.insert(id) }
            let created = Timestamp.string(from: at(Double(index)))
            try HighlightRecord(
                id: id, bookID: seededBooks[index % books], chapterID: nil, spineHref: nil,
                chapterTitle: "Chapter \(index % 20)", quoteExact: words.joined(separator: " "),
                quotePrefix: "", quoteSuffix: "", charStart: nil, charEnd: nil, wordIdx: nil, wordCount: nil,
                progression: nil, totalProgression: Double(index) / Double(count), position: nil,
                cssSelector: nil, partialCFI: nil, domRangeJSON: nil, locatorJSON: "{}", readiumVersion: nil,
                chapterTextHash: nil, anchorStatus: "exact", anchorScore: nil, lastAnchoredAt: created,
                color: HighlightColor.allCases[index % HighlightColor.allCases.count].rawValue,
                note: index % 3 == 0 ? "note \(vocabulary[next() % vocabulary.count])" : "",
                style: "highlight", exportReadwiseAt: nil, createdAt: created, updatedAt: created, deletedAt: nil
            ).insert(db)
        }
        return rare
    }
}

@Suite struct QuoteSearchPerformanceTests {
    /// Measured on a file-backed `DatabasePool` (WAL), like the app's database, not in memory.
    @Test func wordSearchOver1000HighlightsIsUnder100ms() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-fts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.open(at: directory.appendingPathComponent("db.sqlite"))
        let expected = try await seedHighlights(db, count: 1_000, books: 10, rareWord: "zephyr", rareEvery: 37)
        #expect(expected.count == 28)
        #expect(try await ftsRowCount(db) == 1_000)

        let clock = ContinuousClock()
        func best(_ search: String, runs: Int = 5) async throws -> (Duration, [QuoteItem]) {
            var fastest = Duration.seconds(60)
            var result: [QuoteItem] = []
            for _ in 0..<runs {
                var items: [QuoteItem] = []
                let elapsed = try await clock.measure {
                    items = try await db.reader.read { try QuoteRequests.quotes(QuoteFilter(search: search)).fetchAll($0) }
                }
                fastest = min(fastest, elapsed)
                result = items
            }
            return (fastest, result)
        }

        let (rareTime, rareItems) = try await best("zephyr")
        #expect(Set(rareItems.map(\.id)) == expected)
        #expect(rareItems.count == expected.count)
        let (prefixTime, prefixItems) = try await best("zeph")
        #expect(Set(prefixItems.map(\.id)) == expected)
        let (allTime, allItems) = try await best("common")
        #expect(allItems.count == 1_000)

        print("M4 search over 1,000 highlights (file DatabasePool, best of 5): "
              + "rare word \(rareTime), prefix \(prefixTime), all-match \(allTime)")
        #expect(rareTime < .milliseconds(100))
        #expect(prefixTime < .milliseconds(100))
        #expect(allTime < .milliseconds(100))
    }
}
