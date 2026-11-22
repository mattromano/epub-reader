import Foundation
import GRDB
import Importing

// SCAFFOLD STUBS — Agent A implements. Signatures are the contract.
extension AppDatabase {
    /// Replaces the book's dim_chapter + dim_word_anchor rows in one transaction and sets
    /// dim_book.word_count (linear total), chapter_count, index_version, updated_at.
    public func saveIndex(bookID: String, chapters: [ChapterIndex], version: Int, now: Date = Date()) async throws {}

    /// Fixed layout or whole-book failure: index_version = version, word_count stays NULL.
    public func markIndexSkipped(bookID: String, version: Int, now: Date = Date()) async throws {}

    /// Loads chapters + anchors into a `WordIndex`; nil if the book has no dim_chapter rows.
    public func loadWordIndex(bookID: String) async throws -> WordIndex? { nil }

    /// Non-deleted books with index_version < version.
    public func booksNeedingIndex(version: Int) async throws -> [BookRecord] { [] }
}
