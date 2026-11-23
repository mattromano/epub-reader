import Foundation
import GRDB
import Persistence

extension MetricsQueries {
    /// Σ active_seconds of non-deleted finished sessions on reading day `today`.
    public static func todayFinishedActiveSeconds(_ db: Database, today: String) throws -> Double {
        0  // TODO(Task 3)
    }

    /// Everything `ReaderStatsBaseline` holds, for `bookID`, as of `now`.
    public static func readerStatsBaseline(_ db: Database, bookID: String, now: Date = Date(),
                                           timeZone: TimeZone = .current) throws -> ReaderStatsBaseline {
        ReaderStatsBaseline(today: "", usualWPM: nil, todayFinishedSeconds: 0, goalMinutes: nil)  // TODO(Task 3)
    }

    /// The stored reader-stats settings (defaults when unset).
    public static func readerStatsSettings(_ db: Database) throws -> ReaderStatsSettings {
        .default  // TODO(Task 3)
    }
}
