import Foundation
import GRDB

extension MetricsQueries {
    /// SPEC §6.3 Time-of-day profile (v1): Σ active minutes by weekday × `local_start_hour` of
    /// non-deleted sessions with reading day in `[from, to]`. Only non-zero cells are returned,
    /// ordered by weekday then hour.
    /// - `weekday` is Calendar-style, 1 = Sunday … 7 = Saturday, of the session's reading day
    ///   (`local_date`), not of the wall-clock start: a 02:00 session with day start 4 counts toward
    ///   the previous day's weekday, at hour 2. `strftime('%w', local_date)` is date arithmetic on
    ///   an already-local date, not timezone math.
    /// - `hour` is `local_start_hour` (written in Swift at session end); the whole session is
    ///   attributed to its start hour.
    public static func hourWeekdayProfile(_ db: Database, from: String,
                                          to: String) throws -> [(weekday: Int, hour: Int, minutes: Double)] {
        try Row.fetchAll(db, sql: """
            WITH sessions AS (
                SELECT local_date, local_start_hour, active_seconds
                FROM fact_reading_session
                WHERE deleted_at IS NULL AND book_id IS NOT NULL AND local_start_hour IS NOT NULL
                  AND local_date BETWEEN :from AND :to
            ),
            cells AS (
                SELECT CAST(strftime('%w', local_date) AS INTEGER) + 1 AS weekday,
                       local_start_hour AS hour,
                       SUM(active_seconds) / 60.0 AS minutes
                FROM sessions
                GROUP BY weekday, hour
            )
            SELECT weekday, hour, minutes
            FROM cells
            ORDER BY weekday, hour
            """, arguments: ["from": from, "to": to])
            .map { (weekday: $0["weekday"], hour: $0["hour"], minutes: $0["minutes"]) }
    }
}
