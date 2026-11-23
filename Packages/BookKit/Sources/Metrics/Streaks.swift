import Foundation
import GRDB

public struct StreakSummary: Sendable, Equatable, Hashable {
    /// Consecutive qualifying days ending today, or yesterday if today doesn't qualify yet.
    public var current: Int
    /// The longest run ever (up to `today`).
    public var longest: Int
    /// True when today already qualifies and is part of `current`.
    public var currentIncludesToday: Bool

    public init(current: Int, longest: Int, currentIncludesToday: Bool) {
        self.current = current
        self.longest = longest
        self.currentIncludesToday = currentIncludesToday
    }
}

extension MetricsQueries {
    /// SPEC §6.3 Qualifying day / Current streak / Longest streak; §6.4 gaps-and-islands.
    /// A qualifying day has `active_minutes ≥ minMinutes` (bind `AppDatabase.streakMinMinutes`).
    /// Days after `today` are ignored. `yesterday` is computed in Swift and bound.
    public static func streaks(_ db: Database, today: String, minMinutes: Double) throws -> StreakSummary {
        let yesterday = try shift(today, by: -1)
        let row = try Row.fetchOne(db, sql: streaksSQL,
                                   arguments: ["min_minutes": minMinutes, "today": today, "yesterday": yesterday])
        return StreakSummary(current: row?["current_streak"] ?? 0, longest: row?["longest_streak"] ?? 0,
                             currentIncludesToday: row?["includes_today"] ?? false)
    }

    /// Runs of consecutive qualifying days: `julianday(date) − row_number` is constant within a run.
    /// Only one run can end on today or yesterday (two such runs would be adjacent, i.e. one run).
    static let streaksSQL = """
        WITH qualifying AS (
            SELECT local_date
            FROM agg_daily_reading
            WHERE active_minutes >= :min_minutes AND local_date <= :today
        ),
        islands AS (
            SELECT local_date,
                   julianday(local_date) - ROW_NUMBER() OVER (ORDER BY local_date) AS grp
            FROM qualifying
        ),
        runs AS (
            SELECT MIN(local_date) AS run_start, MAX(local_date) AS run_end, COUNT(*) AS run_days
            FROM islands
            GROUP BY grp
        )
        SELECT COALESCE(MAX(CASE WHEN run_end IN (:today, :yesterday) THEN run_days END), 0) AS current_streak,
               COALESCE(MAX(run_days), 0) AS longest_streak,
               COALESCE(MAX(CASE WHEN run_end = :today THEN 1 END), 0) AS includes_today
        FROM runs
        """
}
