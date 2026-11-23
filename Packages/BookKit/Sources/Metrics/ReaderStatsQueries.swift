import Foundation
import GRDB
import Persistence

extension MetricsQueries {
    /// Σ active_seconds of non-deleted finished sessions on reading day `today`.
    public static func todayFinishedActiveSeconds(_ db: Database, today: String) throws -> Double {
        try Double.fetchOne(db, sql: todayFinishedActiveSecondsSQL, arguments: ["today": today]) ?? 0
    }

    /// Reader-stats design, "today vs goal": the active seconds already banked on reading day
    /// `:today`, across all books and all non-deleted sessions (pace-eligible or not). The live
    /// session is not in this number; the reader adds it on top.
    static let todayFinishedActiveSecondsSQL = """
        WITH today_sessions AS (
            SELECT active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date = :today
        )
        SELECT COALESCE(SUM(active_seconds), 0) AS active_seconds
        FROM today_sessions
        """

    /// Everything `ReaderStatsBaseline` holds, for `bookID`, as of `now`.
    public static func readerStatsBaseline(_ db: Database, bookID: String, now: Date = Date(),
                                           timeZone: TimeZone = .current) throws -> ReaderStatsBaseline {
        let today = try today(db, now: now, timeZone: timeZone)
        return ReaderStatsBaseline(
            today: today,
            usualWPM: try bookPace(db, bookID: bookID, today: today),
            todayFinishedSeconds: try todayFinishedActiveSeconds(db, today: today),
            goalMinutes: try GoalRequests.current(.dailyMinutes).fetchOne(db)?.target)
    }

    /// The stored reader-stats settings (defaults when unset).
    public static func readerStatsSettings(_ db: Database) throws -> ReaderStatsSettings {
        ReaderStatsSettings.decode(
            panelJSON: try AppDatabase.settingJSON(db, key: ReaderStatsSettings.panelKey),
            lineJSON: try AppDatabase.settingJSON(db, key: ReaderStatsSettings.lineKey))
    }
}
