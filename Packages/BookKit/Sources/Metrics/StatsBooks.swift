import Foundation
import GRDB
import Persistence

// Stats tab: the Year in reading and Books detail screens, and the per-book stats page
// (stats-tab design).

public struct BookSummary: Sendable, Equatable, Hashable, Identifiable {
    public var bookID: String
    public var title: String
    public var authors: String
    public var status: String
    public var activeMinutes: Double
    public var wpm: Double?
    public var pctComplete: Double?
    public var lastReadDate: String?
    public var id: String { bookID }

    public init(bookID: String, title: String, authors: String, status: String, activeMinutes: Double,
                wpm: Double?, pctComplete: Double?, lastReadDate: String?) {
        self.bookID = bookID
        self.title = title
        self.authors = authors
        self.status = status
        self.activeMinutes = activeMinutes
        self.wpm = wpm
        self.pctComplete = pctComplete
        self.lastReadDate = lastReadDate
    }
}

/// Reading time and speed in one chapter, from counted page-turn/scroll location events.
public struct ChapterPace: Sendable, Equatable, Hashable, Identifiable {
    public var chapterID: String
    public var title: String?
    public var spineIndex: Int
    public var minutes: Double
    public var wordsRead: Int
    /// nil under 1 minute.
    public var wpm: Double?
    public var id: String { chapterID }

    public init(chapterID: String, title: String?, spineIndex: Int, minutes: Double, wordsRead: Int, wpm: Double?) {
        self.chapterID = chapterID
        self.title = title
        self.spineIndex = spineIndex
        self.minutes = minutes
        self.wordsRead = wordsRead
        self.wpm = wpm
    }
}

extension MetricsQueries {
    /// Per-event time cap for chapter pace (the tracker's idle threshold).
    public static let chapterPaceGapCapSeconds = 180.0
    /// Days of recent reading the projected finish date is based on.
    public static let projectionWindowDays = 14

    /// Minutes read on each day of `year` that has reading, oldest first. Stats-tab design "Year in
    /// reading": non-deleted sessions whose `local_date` falls in the year (string comparison).
    public static func calendarDays(_ db: Database, year: Int) throws -> [(localDate: String, minutes: Double)] {
        try Row.fetchAll(db, sql: calendarDaysSQL, arguments: yearBounds(year)).map {
            (localDate: $0["local_date"], minutes: $0["minutes"])
        }
    }

    /// Minutes read per month of `year`, months 1…12 all present (0 when none).
    public static func minutesByMonth(_ db: Database, year: Int) throws -> [(month: Int, minutes: Double)] {
        try Row.fetchAll(db, sql: minutesByMonthSQL, arguments: yearBounds(year)).map {
            (month: $0["month"], minutes: $0["minutes"])
        }
    }

    /// Books with at least one session, most recently read first.
    public static func bookSummaries(_ db: Database) throws -> [BookSummary] {
        try Row.fetchAll(db, sql: bookSummariesSQL).map { row in
            BookSummary(bookID: row["book_id"], title: row["title"], authors: row["authors"] ?? "",
                        status: row["status"] ?? "", activeMinutes: row["total_active_minutes"],
                        wpm: row["avg_wpm"], pctComplete: row["pct_complete"],
                        lastReadDate: row["last_read_date"])
        }
    }

    /// Chapters of `bookID` with counted reading, in spine order.
    public static func chapterPace(_ db: Database, bookID: String) throws -> [ChapterPace] {
        try Row.fetchAll(db, sql: chapterPaceSQL, arguments: ["book_id": bookID, "cap": chapterPaceGapCapSeconds])
            .map { row in
                let minutes: Double = row["minutes"]
                let words: Int = row["words"]
                return ChapterPace(chapterID: row["chapter_id"], title: row["title"],
                                   spineIndex: row["spine_index"] ?? 0, minutes: minutes, wordsRead: words,
                                   wpm: minutes >= 1 ? Double(words) / minutes : nil)
            }
    }

    /// Reading day the book would be finished at the last `projectionWindowDays` days' rate on it
    /// (words read on the book in that window ÷ window days); nil when not indexed, finished, or
    /// no reading on it in the window.
    public static func projectedFinish(_ db: Database, bookID: String, today: String) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: projectedFinishSQL, arguments: [
            "book_id": bookID, "start": try shift(today, by: -(projectionWindowDays - 1)), "today": today,
        ]) else { return nil }
        let wordsLeft: Int = row["words_left"] ?? 0
        let windowWords: Int = row["window_words"] ?? 0
        guard wordsLeft > 0, windowWords > 0 else { return nil }
        let perDay = Double(windowWords) / Double(projectionWindowDays)
        return ReadingDays.adding(Int((Double(wordsLeft) / perDay).rounded(.up)), to: today)
    }

    /// Highlights per 10,000 words read on the book; nil with no words read.
    public static func highlightDensity(_ db: Database, bookID: String) throws -> Double? {
        try Double.fetchOne(db, sql: highlightDensitySQL, arguments: ["book_id": bookID])
    }

    private static func yearBounds(_ year: Int) -> StatementArguments {
        ["first": String(format: "%04d-01-01", year), "last": String(format: "%04d-12-31", year)]
    }

    /// Stats-tab "Year in reading" calendar: minutes per reading day inside the year.
    static let calendarDaysSQL = """
        SELECT local_date, SUM(active_seconds) / 60.0 AS minutes
        FROM fact_reading_session
        WHERE deleted_at IS NULL AND local_date BETWEEN :first AND :last
        GROUP BY local_date
        ORDER BY local_date
        """

    /// Stats-tab "Year in reading" minutes per month: always 12 rows from a recursive month CTE.
    static let minutesByMonthSQL = """
        WITH RECURSIVE months(month) AS (
            SELECT 1
            UNION ALL
            SELECT month + 1 FROM months WHERE month < 12
        ),
        sessions AS (
            SELECT CAST(SUBSTR(local_date, 6, 2) AS INTEGER) AS month, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date BETWEEN :first AND :last
        ),
        monthly AS (
            SELECT month, SUM(active_seconds) / 60.0 AS minutes
            FROM sessions
            GROUP BY month
        )
        SELECT m.month, COALESCE(t.minutes, 0) AS minutes
        FROM months AS m
        LEFT JOIN monthly AS t ON t.month = m.month
        ORDER BY m.month
        """

    /// Stats-tab "Books" list: `agg_book_stats` joined to live books, most recently read first.
    static let bookSummariesSQL = """
        SELECT b.book_id, b.title, b.authors, b.status, a.total_active_minutes, a.avg_wpm, a.pct_complete,
               a.last_read_date
        FROM dim_book AS b
        JOIN agg_book_stats AS a ON a.book_id = b.book_id
        WHERE b.deleted_at IS NULL AND a.sessions > 0
        ORDER BY a.last_read_date DESC, b.title, b.book_id
        """

    /// Stats-tab per-book chapter pace: counted events, each gap capped at `:cap` seconds.
    static let chapterPaceSQL = """
        WITH events AS (
            SELECT chapter_id,
                   MIN(COALESCE(seconds_since_prev, 0), :cap) AS seconds,
                   COALESCE(words_delta, 0) AS words
            FROM fact_location_event
            WHERE book_id = :book_id AND is_counted = 1 AND chapter_id IS NOT NULL
        ),
        per_chapter AS (
            SELECT chapter_id, SUM(seconds) / 60.0 AS minutes, SUM(words) AS words
            FROM events
            GROUP BY chapter_id
        )
        SELECT c.chapter_id, c.title, c.spine_index, p.minutes, p.words
        FROM per_chapter AS p
        JOIN dim_chapter AS c ON c.chapter_id = p.chapter_id
        ORDER BY c.spine_index, c.chapter_id
        """

    /// Stats-tab per-book projected finish inputs: words left and words read in the window.
    static let projectedFinishSQL = """
        WITH book AS (
            SELECT book_id, word_count
            FROM dim_book
            WHERE book_id = :book_id AND deleted_at IS NULL AND status <> 'finished' AND word_count > 0
        ),
        sessions AS (
            SELECT s.local_date, s.words_read, s.end_word_idx
            FROM fact_reading_session AS s
            JOIN book AS b ON b.book_id = s.book_id
            WHERE s.deleted_at IS NULL
        ),
        progress AS (
            SELECT COALESCE(MAX(end_word_idx), 0) AS max_idx,
                   COALESCE(SUM(CASE WHEN local_date BETWEEN :start AND :today THEN words_read END), 0)
                     AS window_words
            FROM sessions
        )
        SELECT b.word_count - p.max_idx AS words_left, p.window_words
        FROM book AS b
        CROSS JOIN progress AS p
        """

    /// Stats-tab per-book highlight density: live highlights per 10,000 words read.
    static let highlightDensitySQL = """
        WITH words AS (
            SELECT a.book_id, a.total_words_read
            FROM agg_book_stats AS a
            JOIN dim_book AS b ON b.book_id = a.book_id AND b.deleted_at IS NULL
            WHERE a.book_id = :book_id AND a.total_words_read > 0
        ),
        marks AS (
            SELECT COUNT(*) AS highlights
            FROM fact_highlight
            WHERE book_id = :book_id AND deleted_at IS NULL
        )
        SELECT m.highlights * 10000.0 / w.total_words_read
        FROM words AS w
        CROSS JOIN marks AS m
        """
}
