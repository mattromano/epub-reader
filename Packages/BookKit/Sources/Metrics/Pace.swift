import Foundation
import GRDB

extension MetricsQueries {
    /// Minimum eligible active seconds in the 14-day window before rolling pace trusts it (20 min).
    static let rollingMinSeconds = 20.0 * 60
    /// Minimum eligible active seconds on a book before book pace is used (15 min).
    static let bookMinSeconds = 15.0 * 60

    /// SPEC §6.3 Rolling pace: Σ words_read / Σ active minutes over pace-eligible, non-deleted
    /// sessions in the 14 reading days ending `today`, if they hold ≥ 20 active minutes; else the
    /// same ratio over 90 days; nil if the 90-day window has no eligible time.
    /// A ratio of sums, never an average of per-session ratios.
    public static func rollingPace(_ db: Database, today: String) throws -> Double? {
        try Double.fetchOne(db, sql: rollingPaceSQL, arguments: [
            "today": today,
            "start14": try shift(today, by: -13),
            "start90": try shift(today, by: -89),
            "min_seconds": rollingMinSeconds,
        ])
    }

    static let rollingPaceSQL = """
        WITH eligible AS (
            SELECT local_date, words_read, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND is_pace_eligible = 1 AND book_id IS NOT NULL
              AND local_date BETWEEN :start90 AND :today
        ),
        windows AS (
            SELECT SUM(CASE WHEN local_date >= :start14 THEN words_read END) AS words_14,
                   SUM(CASE WHEN local_date >= :start14 THEN active_seconds END) AS seconds_14,
                   SUM(words_read) AS words_90,
                   SUM(active_seconds) AS seconds_90
            FROM eligible
        )
        SELECT CASE WHEN seconds_14 >= :min_seconds THEN words_14 * 60.0 / seconds_14
                    WHEN seconds_90 > 0 THEN words_90 * 60.0 / seconds_90
               END AS pace_wpm
        FROM windows
        """

    /// SPEC §6.3 Book pace: the ratio of sums over this book's pace-eligible, non-deleted sessions
    /// (all time) once they total ≥ 15 active minutes; otherwise `rollingPace(today:)`.
    public static func bookPace(_ db: Database, bookID: String, today: String) throws -> Double? {
        let pace = try Double.fetchOne(db, sql: bookPaceSQL, arguments: [
            "book_id": bookID, "min_seconds": bookMinSeconds,
        ])
        if let pace { return pace }
        return try rollingPace(db, today: today)
    }

    static let bookPaceSQL = """
        WITH eligible AS (
            SELECT words_read, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND is_pace_eligible = 1 AND book_id = :book_id
              AND local_date IS NOT NULL
        ),
        totals AS (
            SELECT SUM(words_read) AS words, SUM(active_seconds) AS seconds
            FROM eligible
        )
        SELECT CASE WHEN seconds >= :min_seconds THEN words * 60.0 / seconds END AS pace_wpm
        FROM totals
        """

    /// SPEC §6.3 Session WPM: `words_read / (active_seconds / 60)` for each pace-eligible,
    /// non-deleted session with reading day in `[from, to]`, in reading order. For display (e.g. the
    /// dashboard WPM line); never average these into a pace.
    public static func sessionWPM(_ db: Database, from: String, to: String) throws -> [(localDate: String, wpm: Double)] {
        try Row.fetchAll(db, sql: """
            WITH eligible AS (
                SELECT local_date, started_at, words_read, active_seconds
                FROM fact_reading_session
                WHERE deleted_at IS NULL AND is_pace_eligible = 1 AND active_seconds > 0
                  AND book_id IS NOT NULL AND local_date BETWEEN :from AND :to
            )
            SELECT local_date, words_read * 60.0 / active_seconds AS wpm
            FROM eligible
            ORDER BY local_date, started_at
            """, arguments: ["from": from, "to": to]).map { (localDate: $0["local_date"], wpm: $0["wpm"]) }
    }
}
