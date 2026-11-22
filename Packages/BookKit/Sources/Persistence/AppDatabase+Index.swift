import Foundation
import GRDB
import Importing

// Word index persistence (SPEC §5.2 dim_chapter / dim_word_anchor).
extension AppDatabase {
    /// Replaces the book's dim_chapter + dim_word_anchor rows in one transaction and sets
    /// dim_book.word_count (linear total), chapter_count, index_version, updated_at.
    /// `chapter_count` counts every spine item (one dim_chapter row each), linear or not.
    public func saveIndex(bookID: String, chapters: [ChapterIndex], version: Int, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        let linearWords = WordIndex(bookID: bookID, chapters: chapters).totalWords
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM dim_word_anchor WHERE book_id = ?", arguments: [bookID])
            try db.execute(sql: "DELETE FROM dim_chapter WHERE book_id = ?", arguments: [bookID])

            let insertChapter = try db.makeStatement(sql: """
                INSERT INTO dim_chapter (chapter_id, book_id, spine_index, href, title, is_linear,
                                         word_count, char_count, cum_words_start, text_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insertAnchor = try db.makeStatement(sql: """
                INSERT INTO dim_word_anchor (anchor_id, book_id, chapter_id, block_index, progression,
                                             char_offset, cum_word_offset)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """)
            for chapter in chapters {
                let chapterID = WordIndex.chapterID(bookID: bookID, spineIndex: chapter.spineIndex)
                try insertChapter.execute(arguments: [
                    chapterID, bookID, chapter.spineIndex, chapter.href, chapter.title,
                    chapter.isLinear ? 1 : 0, chapter.wordCount, chapter.charCount,
                    chapter.cumWordsStart, chapter.textHash,
                ])
                for anchor in chapter.anchors {
                    try insertAnchor.execute(arguments: [
                        "\(chapterID):\(anchor.blockIndex)", bookID, chapterID, anchor.blockIndex,
                        anchor.progression, anchor.charOffset, anchor.cumWordOffset,
                    ])
                }
            }

            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET word_count = ?, chapter_count = ?, index_version = ?, updated_at = ?
                    WHERE book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [linearWords, chapters.count, version, nowString, bookID])
        }
    }

    /// Fixed layout or whole-book failure: index_version = version, word_count stays NULL.
    public func markIndexSkipped(bookID: String, version: Int, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET index_version = ?, updated_at = ?
                    WHERE book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [version, nowString, bookID])
        }
    }

    /// Loads chapters + anchors into a `WordIndex`; nil if the book has no dim_chapter rows.
    public func loadWordIndex(bookID: String) async throws -> WordIndex? {
        try await writer.read { db in
            let chapterRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chapter_id, spine_index, href, title, is_linear, word_count, char_count,
                           cum_words_start, text_hash
                    FROM dim_chapter
                    WHERE book_id = ?
                    ORDER BY spine_index
                    """,
                arguments: [bookID])
            guard !chapterRows.isEmpty else { return nil }

            var anchorsByChapter: [String: [BlockAnchor]] = [:]
            let anchorRows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT chapter_id, block_index, progression, char_offset, cum_word_offset
                    FROM dim_word_anchor
                    WHERE book_id = ?
                    ORDER BY chapter_id, block_index
                    """,
                arguments: [bookID])
            while let row = try anchorRows.next() {
                let anchor = BlockAnchor(
                    blockIndex: row["block_index"] ?? 0,
                    progression: row["progression"] ?? 0,
                    charOffset: row["char_offset"] ?? 0,
                    cumWordOffset: row["cum_word_offset"] ?? 0)
                anchorsByChapter[row["chapter_id"] as String, default: []].append(anchor)
            }

            let chapters = chapterRows.map { row in
                let chapterID: String = row["chapter_id"]
                return ChapterIndex(
                    spineIndex: row["spine_index"] ?? 0,
                    href: row["href"] ?? "",
                    title: row["title"] ?? "",
                    isLinear: (row["is_linear"] as Int? ?? 1) != 0,
                    wordCount: row["word_count"] ?? 0,
                    charCount: row["char_count"] ?? 0,
                    cumWordsStart: row["cum_words_start"] ?? 0,
                    textHash: row["text_hash"] ?? "",
                    anchors: anchorsByChapter[chapterID] ?? [])
            }
            return WordIndex(bookID: bookID, chapters: chapters)
        }
    }

    /// Non-deleted books with index_version < version, oldest first.
    public func booksNeedingIndex(version: Int) async throws -> [BookRecord] {
        try await writer.read { db in
            try BookRecord
                .filter(BookRecord.Columns.deletedAt == nil)
                .filter(BookRecord.Columns.indexVersion < version)
                .order(BookRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }
}
