import Foundation
import GRDB
import Importing
import Testing
@testable import Persistence

private func newBook(_ hash: String) -> NewBook {
    NewBook(contentHash: hash, title: "Book \(hash)", authors: "A",
            fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1)
}

private func at(_ s: String) -> Date { Timestamp.date(from: s)! }

private func insertBook(_ db: AppDatabase, _ hash: String, now: String = "2026-11-22T07:00:00.000Z") async throws -> String {
    guard case .inserted(let record) = try await db.importBook(newBook(hash), now: at(now)) else {
        Issue.record("expected insert")
        return ""
    }
    return record.id
}

private func sampleChapters(wordsPerChapter: [Int] = [12, 40, 7], nonLinear: Set<Int> = []) -> [ChapterIndex] {
    let inputs = wordsPerChapter.enumerated().map { spine, words in
        let half = words / 2
        let xhtml = "<p>" + (0..<half).map { "a\($0)" }.joined(separator: " ") + "</p><p>"
            + (half..<words).map { "b\($0)" }.joined(separator: " ") + "</p>"
        return IndexInputChapter(spineIndex: spine, href: "ch\(spine).xhtml",
                                 title: spine == 0 ? nil : "Chapter \(spine)",
                                 isLinear: !nonLinear.contains(spine), xhtml: xhtml)
    }
    return WordIndexer.index(inputs)
}

private func count(_ db: AppDatabase, _ sql: String, _ args: StatementArguments = []) async throws -> Int {
    try await db.reader.read { try Int.fetchOne($0, sql: sql, arguments: args) ?? 0 }
}

@Suite struct IndexMigrationTests {
    @Test func migrationCreatesTables() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let chapterColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(dim_chapter)").map { $0["name"] as String }
            #expect(chapterColumns == [
                "chapter_id", "book_id", "spine_index", "href", "title", "is_linear", "word_count",
                "char_count", "cum_words_start", "text_hash",
            ])
            let anchorColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(dim_word_anchor)").map { $0["name"] as String }
            #expect(anchorColumns == [
                "anchor_id", "book_id", "chapter_id", "block_index", "progression", "char_offset",
                "cum_word_offset",
            ])
            let chapterIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(dim_chapter)")
            #expect(chapterIndexes.contains { ($0["name"] as String) == "idx_dim_chapter_book_spine" })
            let anchorIndexes = try Row.fetchAll(db, sql: "PRAGMA index_list(dim_word_anchor)")
            let unique = anchorIndexes.filter { ($0["unique"] as Int) == 1 && ($0["origin"] as String) == "c" }
            #expect(unique.map { $0["name"] as String } == ["idx_dim_word_anchor_chapter_block"])
            let uniqueCols = try Row.fetchAll(db, sql: "PRAGMA index_info(idx_dim_word_anchor_chapter_block)")
                .map { $0["name"] as String }
            #expect(uniqueCols == ["chapter_id", "block_index"])
        }
    }

    @Test func deletingChapterCascadesToAnchors() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        try await db.saveIndex(bookID: bookID, chapters: sampleChapters(), version: 1)
        try await db.writer.write { try $0.execute(sql: "DELETE FROM dim_chapter WHERE book_id = ?", arguments: [bookID]) }
        #expect(try await count(db, "SELECT COUNT(*) FROM dim_word_anchor") == 0)
    }
}

@Suite struct IndexPersistenceTests {
    @Test func saveAndLoadRoundTrips() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        let chapters = sampleChapters(nonLinear: [1])
        try await db.saveIndex(bookID: bookID, chapters: chapters, version: 1)

        let loaded = try #require(try await db.loadWordIndex(bookID: bookID))
        #expect(loaded.bookID == bookID)
        #expect(loaded.chapters == chapters)
        #expect(loaded.totalWords == 19)
        #expect(loaded.chapters[0].title == "Section 1")
        #expect(loaded.chapterID(href: "ch2.xhtml") == "\(bookID):2")
        #expect(loaded.wordIdx(href: "ch2.xhtml", progression: 1) == 19)

        let anchorIDs = try await db.reader.read {
            try String.fetchAll($0, sql: "SELECT anchor_id FROM dim_word_anchor WHERE chapter_id = ? ORDER BY block_index",
                                arguments: ["\(bookID):1"])
        }
        #expect(anchorIDs == ["\(bookID):1:0", "\(bookID):1:1"])
    }

    @Test func loadReturnsNilWithoutChapters() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        #expect(try await db.loadWordIndex(bookID: bookID) == nil)
        #expect(try await db.loadWordIndex(bookID: "missing") == nil)
    }

    @Test func reindexReplacesRows() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        let other = try await insertBook(db, "h2")
        try await db.saveIndex(bookID: bookID, chapters: sampleChapters(wordsPerChapter: [10, 10, 10, 10]), version: 1)
        try await db.saveIndex(bookID: other, chapters: sampleChapters(), version: 1)

        let fewer = sampleChapters(wordsPerChapter: [30, 4])
        try await db.saveIndex(bookID: bookID, chapters: fewer, version: 2)

        #expect(try await count(db, "SELECT COUNT(*) FROM dim_chapter WHERE book_id = ?", [bookID]) == 2)
        #expect(try await count(db, "SELECT COUNT(*) FROM dim_word_anchor WHERE book_id = ?", [bookID]) == 4)
        // Other book untouched.
        #expect(try await count(db, "SELECT COUNT(*) FROM dim_chapter WHERE book_id = ?", [other]) == 3)
        #expect(try await count(db, "SELECT COUNT(*) FROM dim_word_anchor WHERE book_id = ?", [other]) == 6)
        let loaded = try #require(try await db.loadWordIndex(bookID: bookID))
        #expect(loaded.chapters == fewer)
    }

    @Test func saveUpdatesBookColumns() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        try await db.saveIndex(bookID: bookID, chapters: sampleChapters(nonLinear: [1]), version: 3,
                               now: at("2026-11-23T08:00:00.250Z"))
        let book = try #require(try await db.book(id: bookID))
        #expect(book.wordCount == 19)
        #expect(book.chapterCount == 3)
        #expect(book.indexVersion == 3)
        #expect(book.updatedAt == "2026-11-23T08:00:00.250Z")
    }

    @Test func markIndexSkippedLeavesWordCountNull() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        try await db.markIndexSkipped(bookID: bookID, version: 1, now: at("2026-11-23T09:00:00.000Z"))
        let book = try #require(try await db.book(id: bookID))
        #expect(book.wordCount == nil)
        #expect(book.indexVersion == 1)
        #expect(book.updatedAt == "2026-11-23T09:00:00.000Z")
        #expect(try await db.booksNeedingIndex(version: 1).isEmpty)
    }

    @Test func booksNeedingIndexExcludesDeletedAndCurrent() async throws {
        let db = try AppDatabase.inMemory()
        let stale = try await insertBook(db, "h1", now: "2026-11-22T07:00:03.000Z")
        let current = try await insertBook(db, "h2", now: "2026-11-22T07:00:01.000Z")
        let deleted = try await insertBook(db, "h3", now: "2026-11-22T07:00:02.000Z")
        let older = try await insertBook(db, "h4", now: "2026-11-22T07:00:00.000Z")
        try await db.saveIndex(bookID: current, chapters: sampleChapters(), version: 2)
        try await db.saveIndex(bookID: older, chapters: sampleChapters(), version: 1)
        try await db.softDeleteBook(id: deleted)

        let needing = try await db.booksNeedingIndex(version: 2)
        #expect(needing.map(\.id) == [older, stale])
        #expect(try await db.booksNeedingIndex(version: 1).map(\.id) == [stale])
    }

    @Test func softDeletedBookRowIsNotTouched() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "h1")
        try await db.softDeleteBook(id: bookID, now: at("2026-11-22T08:00:00.000Z"))
        try await db.saveIndex(bookID: bookID, chapters: sampleChapters(), version: 1,
                               now: at("2026-11-22T09:00:00.000Z"))
        try await db.markIndexSkipped(bookID: bookID, version: 2, now: at("2026-11-22T10:00:00.000Z"))
        let row = try db.reader.read { db -> Row? in
            try Row.fetchOne(db, sql: "SELECT word_count, index_version, updated_at FROM dim_book WHERE book_id = ?",
                             arguments: [bookID])
        }
        #expect(row?["word_count"] as Int? == nil)
        #expect(row?["index_version"] as Int? == 0)
        #expect(row?["updated_at"] as String? == "2026-11-22T08:00:00.000Z")
    }

    @Test func saving300kWordBookIsFast() async throws {
        let db = try AppDatabase.inMemory()
        let bookID = try await insertBook(db, "big")
        // 25 chapters, 12k words each, an anchor every ~120 words: ~2,500 anchors.
        let chapters = (0..<25).map { spine in
            ChapterIndex(
                spineIndex: spine, href: "c\(spine).xhtml", title: "C\(spine)", isLinear: true,
                wordCount: 12_000, charCount: 72_000, cumWordsStart: spine * 12_000, textHash: "h",
                anchors: (0..<100).map { k in
                    BlockAnchor(blockIndex: k, progression: Double(k) / 100, charOffset: k * 720,
                                cumWordOffset: k * 120)
                })
        }
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await db.saveIndex(bookID: bookID, chapters: chapters, version: 1)
        }
        #expect(elapsed < .seconds(1), "saveIndex took \(elapsed)")
        #expect(try await count(db, "SELECT COUNT(*) FROM dim_word_anchor") == 2_500)
        #expect(try #require(try await db.book(id: bookID)).wordCount == 300_000)
    }
}
