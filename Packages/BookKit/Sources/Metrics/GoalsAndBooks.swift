import Foundation
import GRDB
import Persistence

/// One row of `agg_book_stats` (SPEC §5.2).
public struct BookStats: Sendable, Equatable, Hashable {
    public var bookID: String
    public var totalActiveMinutes: Double
    public var totalWordsRead: Int
    public var sessions: Int
    public var firstReadDate: String?
    public var lastReadDate: String?
    /// Ratio of sums over pace-eligible sessions.
    public var avgWPM: Double?
    public var medianSessionMinutes: Double?
    public var highlights: Int
    /// Max word index reached ÷ word count when indexed, else the stored Readium total progression.
    public var pctComplete: Double?
}

extension MetricsQueries {
    /// The book's `agg_book_stats` row (nil for a missing or deleted book).
    public static func bookStats(_ db: Database, bookID: String) throws -> BookStats? {
        try Row.fetchOne(db, sql: """
            SELECT book_id, total_active_minutes, total_words_read, sessions, first_read_date, last_read_date,
                   avg_wpm, median_session_minutes, highlights, pct_complete
            FROM agg_book_stats
            WHERE book_id = ?
            """, arguments: [bookID]).map { row in
            BookStats(bookID: row["book_id"], totalActiveMinutes: row["total_active_minutes"],
                      totalWordsRead: row["total_words_read"], sessions: row["sessions"],
                      firstReadDate: row["first_read_date"], lastReadDate: row["last_read_date"],
                      avgWPM: row["avg_wpm"], medianSessionMinutes: row["median_session_minutes"],
                      highlights: row["highlights"], pctComplete: row["pct_complete"])
        }
    }

    // MARK: - Goal hit rate

    /// SPEC §6.3 Goal hit rate: goal-met days / days since the goal started.
    /// - Start: the earliest `valid_from` among non-deleted `daily_minutes` goal rows.
    /// - End: today if today's goal is already met, else yesterday (today is still in progress,
    ///   the same rule as the streak).
    /// - Days without reading count as not met. Nil before the first full day.
    public static func goalHitRate(_ db: Database, today: String) throws -> Double? {
        let row = try Row.fetchOne(db, sql: goalHitRateSQL, arguments: [
            "today": today, "yesterday": try shift(today, by: -1),
        ])
        guard let row, let days: Double = row["period_days"], days >= 1 else { return nil }
        let met: Int = row["met_days"] ?? 0
        return Double(met) / days
    }

    static let goalHitRateSQL = """
        WITH goal_start AS (
            SELECT MIN(valid_from) AS start_date
            FROM dim_goal
            WHERE metric = 'daily_minutes' AND deleted_at IS NULL
        ),
        today_row AS (
            SELECT COALESCE(MAX(goal_met), 0) AS met_today
            FROM agg_daily_reading
            WHERE local_date = :today
        ),
        period AS (
            SELECT gs.start_date,
                   CASE WHEN tr.met_today = 1 THEN :today ELSE :yesterday END AS end_date
            FROM goal_start AS gs
            CROSS JOIN today_row AS tr
        ),
        met AS (
            SELECT COUNT(*) AS met_days
            FROM agg_daily_reading AS a
            JOIN period AS p ON a.local_date BETWEEN p.start_date AND p.end_date
            WHERE a.goal_met = 1
        )
        SELECT julianday(p.end_date) - julianday(p.start_date) + 1 AS period_days, m.met_days
        FROM period AS p
        CROSS JOIN met AS m
        """

    // MARK: - Books finished

    /// SPEC §6.3 Books finished (year): non-deleted `dim_book` rows with status `finished` and
    /// `finished_at` inside reading-year `year` (Jan 1 to Jan 1 reading days, using the stored
    /// `day_start_hour` and `timeZone`). The UTC bounds are computed in Swift; SQL compares strings.
    public static func booksFinished(_ db: Database, year: Int, timeZone: TimeZone = .current) throws -> Int {
        try booksFinishedByMonth(db, year: year, timeZone: timeZone).reduce(0) { $0 + $1.count }
    }

    /// Books finished per reading-month of `year`: always 12 rows (month 1–12), zero-filled.
    public static func booksFinishedByMonth(_ db: Database, year: Int,
                                            timeZone: TimeZone = .current) throws -> [(month: Int, count: Int)] {
        let dayStartHour = try AppDatabase.dayStartHour(db)
        var months: [[String: Any]] = []
        for month in 1...12 {
            let first = String(format: "%04d-%02d-01", year, month)
            let next = month == 12 ? String(format: "%04d-01-01", year + 1) : String(format: "%04d-%02d-01", year, month + 1)
            guard let start = ReadingDays.window(for: first, dayStartHour: dayStartHour, timeZone: timeZone)?.start,
                  let end = ReadingDays.window(for: next, dayStartHour: dayStartHour, timeZone: timeZone)?.start else {
                throw MetricsError.invalidLocalDate(first)
            }
            months.append(["m": month, "s": start, "e": end])
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: months, options: [.sortedKeys]),
                          as: UTF8.self)
        return try Row.fetchAll(db, sql: booksFinishedByMonthSQL, arguments: ["months": json])
            .map { (month: $0["month"], count: $0["books"]) }
    }

    static let booksFinishedByMonthSQL = """
        WITH months AS (
            SELECT json_extract(value, '$.m') AS month,
                   json_extract(value, '$.s') AS window_start,
                   json_extract(value, '$.e') AS window_end
            FROM json_each(:months)
        ),
        finished AS (
            SELECT book_id, finished_at
            FROM dim_book
            WHERE deleted_at IS NULL AND status = 'finished' AND finished_at IS NOT NULL
        )
        SELECT m.month, COUNT(f.book_id) AS books
        FROM months AS m
        LEFT JOIN finished AS f ON f.finished_at >= m.window_start AND f.finished_at < m.window_end
        GROUP BY m.month
        ORDER BY m.month
        """
}
