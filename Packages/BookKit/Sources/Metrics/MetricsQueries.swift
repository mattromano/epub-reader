import Foundation
import GRDB
import Persistence

/// Read-side metric queries (SPEC §6.3–6.4). Every function takes a `Database`, so callers choose
/// the read (`reader.read`, `ValueObservation`, GRDBQuery). Aggregation happens in SQL; Swift only
/// does calendar math (yesterday, window starts, UTC bounds of reading days) and binds the result.
///
/// Day arguments are reading-day `local_date` strings (`YYYY-MM-DD`). Use `today(_:now:timeZone:)`
/// to get the current one.
///
/// The SQL that maintains `agg_*` lives in Persistence (`AppDatabase+Aggregates.swift`), because
/// the write paths refresh it inside their own transactions.
public enum MetricsQueries {
    /// Today's reading day, from the stored `day_start_hour` and `timeZone`.
    public static func today(_ db: Database, now: Date = Date(), timeZone: TimeZone = .current) throws -> String {
        ReadingDays.today(now: now, dayStartHour: try AppDatabase.dayStartHour(db), timeZone: timeZone)
    }

    static func shift(_ localDate: String, by days: Int) throws -> String {
        guard let shifted = ReadingDays.adding(days, to: localDate) else {
            throw MetricsError.invalidLocalDate(localDate)
        }
        return shifted
    }
}

public enum MetricsError: Error, Equatable {
    case invalidLocalDate(String)
}

// MARK: - Daily

/// One row of `agg_daily_reading` (SPEC §5.2): a reading day with at least one session or
/// highlight.
public struct DailyReading: Sendable, Equatable, Hashable {
    public var localDate: String
    public var activeMinutes: Double
    public var wordsRead: Int
    public var sessions: Int
    public var booksTouched: Int
    /// Ratio of sums over the day's pace-eligible sessions; nil if none.
    public var paceWPM: Double?
    /// The `daily_minutes` target valid on the day (SCD2); nil if no goal covered it.
    public var goalMinutes: Double?
    public var goalMet: Bool
    public var highlightsCreated: Int

    public init(localDate: String, activeMinutes: Double, wordsRead: Int, sessions: Int, booksTouched: Int,
                paceWPM: Double?, goalMinutes: Double?, goalMet: Bool, highlightsCreated: Int) {
        self.localDate = localDate
        self.activeMinutes = activeMinutes
        self.wordsRead = wordsRead
        self.sessions = sessions
        self.booksTouched = booksTouched
        self.paceWPM = paceWPM
        self.goalMinutes = goalMinutes
        self.goalMet = goalMet
        self.highlightsCreated = highlightsCreated
    }

    init(row: Row) {
        self.init(localDate: row["local_date"], activeMinutes: row["active_minutes"], wordsRead: row["words_read"],
                  sessions: row["sessions"], booksTouched: row["books_touched"], paceWPM: row["pace_wpm"],
                  goalMinutes: row["goal_minutes"], goalMet: row["goal_met"],
                  highlightsCreated: row["highlights_created"])
    }
}

extension MetricsQueries {
    /// SPEC §6.3 Active minutes (day), Words read (day), Daily goal met. Days in `[from, to]`
    /// (inclusive) that have a row, oldest first. Days with no reading are absent (sparse).
    public static func daily(_ db: Database, from: String, to: String) throws -> [DailyReading] {
        try Row.fetchAll(db, sql: """
            SELECT local_date, active_minutes, words_read, sessions, books_touched, pace_wpm,
                   goal_minutes, goal_met, highlights_created
            FROM agg_daily_reading
            WHERE local_date BETWEEN :from AND :to
            ORDER BY local_date
            """, arguments: ["from": from, "to": to]).map(DailyReading.init(row:))
    }

    /// Dashboard "minutes per day (30/90/365)": the same rows as `daily`.
    public static func minutesPerDay(_ db: Database, from: String, to: String) throws -> [DailyReading] {
        try daily(db, from: from, to: to)
    }
}
