import Foundation
import GRDB
import Persistence

// Stats tab: the Sessions and Personal bests detail screens (stats-tab design).

public struct SessionLogEntry: Sendable, Equatable, Hashable, Identifiable {
    public var sessionID: String
    public var bookID: String?
    /// "" when the book is gone.
    public var bookTitle: String
    /// UTC ISO-8601, as stored.
    public var startedAt: String
    public var localDate: String
    public var activeSeconds: Double
    public var wordsRead: Int
    public var pageTurns: Int
    public var readingMode: String?
    /// words / active minutes for pace-eligible sessions with words; else nil.
    public var wpm: Double?
    public var id: String { sessionID }

    public init(sessionID: String, bookID: String?, bookTitle: String, startedAt: String, localDate: String,
                activeSeconds: Double, wordsRead: Int, pageTurns: Int, readingMode: String?, wpm: Double?) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.localDate = localDate
        self.activeSeconds = activeSeconds
        self.wordsRead = wordsRead
        self.pageTurns = pageTurns
        self.readingMode = readingMode
        self.wpm = wpm
    }
}

/// One bar of the session-length chart: sessions whose active minutes fall in
/// `[lowerMinutes, next bucket's lowerMinutes)`.
public struct SessionLengthBucket: Sendable, Equatable, Hashable, Identifiable {
    /// One of `MetricsQueries.sessionLengthBuckets`.
    public var lowerMinutes: Int
    public var count: Int
    public var id: Int { lowerMinutes }

    public init(lowerMinutes: Int, count: Int) {
        self.lowerMinutes = lowerMinutes
        self.count = count
    }
}

public enum PersonalRecordKind: String, CaseIterable, Sendable {
    case longestSession = "longest_session"
    /// Highest WPM among pace-eligible sessions with ≥ 10 active minutes.
    case fastestSession = "fastest_session"
    case mostMinutesInDay = "most_minutes_in_day"
    case mostWordsInDay = "most_words_in_day"
    case mostPagesInSession = "most_pages_in_session"
    case longestStreak = "longest_streak"
}

public struct PersonalRecord: Sendable, Equatable, Hashable, Identifiable {
    public var kind: PersonalRecordKind
    /// Seconds (longestSession), WPM (fastestSession), minutes (mostMinutesInDay), words,
    /// pages, or days (longestStreak).
    public var value: Double
    /// The reading day it happened; nil for longestStreak.
    public var localDate: String?
    /// For session records; nil for day records and the streak.
    public var bookTitle: String?
    public var id: PersonalRecordKind { kind }

    public init(kind: PersonalRecordKind, value: Double, localDate: String?, bookTitle: String?) {
        self.kind = kind
        self.value = value
        self.localDate = localDate
        self.bookTitle = bookTitle
    }
}

extension MetricsQueries {
    /// Lower bounds (minutes) of the session-length buckets; the last is open-ended.
    public static let sessionLengthBuckets = [0, 5, 10, 20, 30, 45, 60]
    /// Fastest-session records only count sessions at least this long.
    public static let fastestSessionMinSeconds = 600.0

    /// Non-deleted sessions, newest `started_at` first, optionally for one book.
    public static func sessionLog(_ db: Database, bookID: String? = nil, limit: Int = 200) throws -> [SessionLogEntry] {
        try Row.fetchAll(db, sql: sessionLogSQL, arguments: ["book_id": bookID, "limit": limit]).map { row in
            SessionLogEntry(sessionID: row["session_id"], bookID: row["book_id"], bookTitle: row["book_title"],
                            startedAt: row["started_at"], localDate: row["local_date"],
                            activeSeconds: row["active_seconds"], wordsRead: row["words_read"],
                            pageTurns: row["page_turns"], readingMode: row["reading_mode"], wpm: row["wpm"])
        }
    }

    /// Stats-tab design, Sessions screen: the session log. The book title is "" when the book is
    /// missing or deleted; `wpm` is nil unless the session is pace-eligible with words and time.
    static let sessionLogSQL = """
        WITH log AS (
            SELECT s.session_id, s.book_id, b.title AS book_title,
                   COALESCE(s.started_at, '') AS started_at, COALESCE(s.local_date, '') AS local_date,
                   s.active_seconds, s.words_read, s.page_turns, s.reading_mode,
                   CASE WHEN s.is_pace_eligible = 1 AND s.words_read > 0 AND s.active_seconds > 0
                        THEN s.words_read * 60.0 / s.active_seconds
                   END AS wpm
            FROM fact_reading_session AS s
            LEFT JOIN dim_book AS b ON b.book_id = s.book_id AND b.deleted_at IS NULL
            WHERE s.deleted_at IS NULL AND (:book_id IS NULL OR s.book_id = :book_id)
        )
        SELECT session_id, book_id, COALESCE(book_title, '') AS book_title, started_at, local_date,
               active_seconds, words_read, page_turns, reading_mode, wpm
        FROM log
        ORDER BY started_at DESC, session_id
        LIMIT :limit
        """

    /// Every bucket in `sessionLengthBuckets` order (zero counts included) for sessions in `[from, to]`.
    public static func sessionLengthHistogram(_ db: Database, from: String, to: String) throws -> [SessionLengthBucket] {
        let values = sessionLengthBuckets.indices.map { "(:b\($0))" }.joined(separator: ", ")
        var arguments: [String: any DatabaseValueConvertible] = ["from": from, "to": to]
        for (index, lower) in sessionLengthBuckets.enumerated() { arguments["b\(index)"] = lower }
        return try Row.fetchAll(db, sql: sessionLengthHistogramSQL(values: values),
                                arguments: StatementArguments(arguments)).map {
            SessionLengthBucket(lowerMinutes: $0["lower_minutes"], count: $0["session_count"])
        }
    }

    /// Stats-tab design, Sessions screen: session-length histogram. A session lands in the largest
    /// bucket whose lower bound is ≤ its minutes (compared in seconds, so 5.0 min is in the 5 bucket).
    /// `values` is a list of bound placeholders, e.g. `(:b0), (:b1)`.
    static func sessionLengthHistogramSQL(values: String) -> String {
        """
        WITH bounds(lower_minutes) AS (
            VALUES \(values)
        ),
        ranges AS (
            SELECT lower_minutes,
                   LEAD(lower_minutes) OVER (ORDER BY lower_minutes) AS upper_minutes
            FROM bounds
        ),
        sessions AS (
            SELECT active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date BETWEEN :from AND :to
        )
        SELECT r.lower_minutes, COUNT(s.active_seconds) AS session_count
        FROM ranges AS r
        LEFT JOIN sessions AS s
               ON s.active_seconds >= r.lower_minutes * 60.0
              AND (r.upper_minutes IS NULL OR s.active_seconds < r.upper_minutes * 60.0)
        GROUP BY r.lower_minutes
        ORDER BY r.lower_minutes
        """
    }

    /// One record per kind that has data, in `PersonalRecordKind.allCases` order. Ties go to
    /// the earliest. The streak uses `streaks(_:today:minMinutes:)`.
    public static func personalRecords(_ db: Database, today: String, minMinutes: Double) throws -> [PersonalRecord] {
        let rows = try Row.fetchAll(db, sql: personalRecordsSQL,
                                    arguments: ["fastest_min_seconds": fastestSessionMinSeconds])
        var byKind: [PersonalRecordKind: PersonalRecord] = [:]
        for row in rows {
            guard let kind = PersonalRecordKind(rawValue: row["kind"]) else { continue }
            let title: String? = row["book_title"]
            byKind[kind] = PersonalRecord(kind: kind, value: row["value"], localDate: row["local_date"],
                                          bookTitle: title)
        }
        let longest = try streaks(db, today: today, minMinutes: minMinutes).longest
        if longest > 0 {
            byKind[.longestStreak] = PersonalRecord(kind: .longestStreak, value: Double(longest),
                                                    localDate: nil, bookTitle: nil)
        }
        return PersonalRecordKind.allCases.compactMap { byKind[$0] }
    }

    /// Stats-tab design, Personal bests screen: one row per session or day record. Ties go to the
    /// earliest `started_at` / `local_date`; records with value 0 are dropped.
    static let personalRecordsSQL = """
        WITH sessions AS (
            SELECT s.started_at, s.local_date, s.active_seconds, s.words_read, s.page_turns,
                   COALESCE(b.title, '') AS book_title,
                   CASE WHEN s.is_pace_eligible = 1 AND s.words_read > 0
                             AND s.active_seconds >= :fastest_min_seconds
                        THEN s.words_read * 60.0 / s.active_seconds
                   END AS wpm
            FROM fact_reading_session AS s
            LEFT JOIN dim_book AS b ON b.book_id = s.book_id AND b.deleted_at IS NULL
            WHERE s.deleted_at IS NULL AND s.local_date IS NOT NULL
        ),
        days AS (
            SELECT local_date, SUM(active_seconds) / 60.0 AS minutes, SUM(words_read) AS words
            FROM sessions
            GROUP BY local_date
        ),
        longest_session AS (
            SELECT 'longest_session' AS kind, active_seconds AS value, local_date, book_title
            FROM sessions WHERE active_seconds > 0
            ORDER BY active_seconds DESC, started_at LIMIT 1
        ),
        fastest_session AS (
            SELECT 'fastest_session' AS kind, wpm AS value, local_date, book_title
            FROM sessions WHERE wpm > 0
            ORDER BY wpm DESC, started_at LIMIT 1
        ),
        most_minutes_in_day AS (
            SELECT 'most_minutes_in_day' AS kind, minutes AS value, local_date, NULL AS book_title
            FROM days WHERE minutes > 0
            ORDER BY minutes DESC, local_date LIMIT 1
        ),
        most_words_in_day AS (
            SELECT 'most_words_in_day' AS kind, words AS value, local_date, NULL AS book_title
            FROM days WHERE words > 0
            ORDER BY words DESC, local_date LIMIT 1
        ),
        most_pages_in_session AS (
            SELECT 'most_pages_in_session' AS kind, page_turns AS value, local_date, book_title
            FROM sessions WHERE page_turns > 0
            ORDER BY page_turns DESC, started_at LIMIT 1
        )
        SELECT kind, value, local_date, book_title FROM longest_session
        UNION ALL SELECT kind, value, local_date, book_title FROM fastest_session
        UNION ALL SELECT kind, value, local_date, book_title FROM most_minutes_in_day
        UNION ALL SELECT kind, value, local_date, book_title FROM most_words_in_day
        UNION ALL SELECT kind, value, local_date, book_title FROM most_pages_in_session
        """
}
