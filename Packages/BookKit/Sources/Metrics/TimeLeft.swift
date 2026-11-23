import Foundation
import GRDB

public struct TimeLeft: Sendable, Equatable, Hashable {
    /// Minutes to the end of the current chapter; nil when the chapter is unknown, not indexed,
    /// non-linear, or there is no pace yet.
    public var chapterMinutes: Double?
    /// Minutes to the end of the book (linear chapters); nil when the book is not indexed or there
    /// is no pace yet.
    public var bookMinutes: Double?

    public init(chapterMinutes: Double?, bookMinutes: Double?) {
        self.chapterMinutes = chapterMinutes
        self.bookMinutes = bookMinutes
    }
}

extension MetricsQueries {
    /// SPEC §6.3 Time left in chapter / book:
    /// - chapter: `(cum_words_start + word_count − current_word_idx) / book_pace`
    /// - book: `(dim_book.word_count − current_word_idx) / book_pace` (word_count is the linear total)
    /// Remaining words are clamped at 0. `currentWordIdx` comes from `WordIndex` (never Readium
    /// positions).
    public static func timeLeft(_ db: Database, bookID: String, chapterID: String?, currentWordIdx: Int,
                                today: String) throws -> TimeLeft {
        guard let pace = try bookPace(db, bookID: bookID, today: today), pace > 0 else {
            return TimeLeft(chapterMinutes: nil, bookMinutes: nil)
        }
        let row = try Row.fetchOne(db, sql: timeLeftSQL, arguments: [
            "book_id": bookID, "chapter_id": chapterID, "word_idx": currentWordIdx,
        ])
        let chapterWords: Int? = row?["chapter_words_left"]
        let bookWords: Int? = row?["book_words_left"]
        return TimeLeft(chapterMinutes: chapterWords.map { Double($0) / pace },
                        bookMinutes: bookWords.map { Double($0) / pace })
    }

    static let timeLeftSQL = """
        WITH book AS (
            SELECT book_id, word_count
            FROM dim_book
            WHERE book_id = :book_id AND deleted_at IS NULL AND word_count > 0
        ),
        chapter AS (
            SELECT c.book_id, c.cum_words_start + c.word_count AS chapter_end
            FROM dim_chapter AS c
            JOIN book AS b ON b.book_id = c.book_id
            WHERE c.chapter_id = :chapter_id AND c.is_linear = 1
        )
        SELECT MAX(0, b.word_count - :word_idx) AS book_words_left,
               MAX(0, c.chapter_end - :word_idx) AS chapter_words_left
        FROM book AS b
        LEFT JOIN chapter AS c ON c.book_id = b.book_id
        """
}
