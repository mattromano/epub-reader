import Foundation
import GRDB
import Persistence

// Stats tab: overview headline numbers and the Speed detail screen (stats-tab design).

/// Everything you've ever read (non-deleted sessions and books).
public struct LifetimeTotals: Sendable, Equatable, Hashable {
    public var activeSeconds: Double
    public var wordsRead: Int
    public var sessions: Int
    /// Books with status `finished` (any year).
    public var booksFinished: Int

    /// Words read ÷ 90,000 (a typical novel).
    public var novelEquivalent: Double { Double(wordsRead) / 90_000 }

    public init(activeSeconds: Double, wordsRead: Int, sessions: Int, booksFinished: Int) {
        self.activeSeconds = activeSeconds
        self.wordsRead = wordsRead
        self.sessions = sessions
        self.booksFinished = booksFinished
    }
}

/// Pace over the last 14 reading days vs the last 90 (both ratio-of-sums over pace-eligible
/// sessions, no minimum-minutes fallback).
public struct PaceComparison: Sendable, Equatable, Hashable {
    public var pace14: Double?
    public var pace90: Double?
    /// (pace14 / pace90 − 1) × 100; nil unless both exist.
    public var deltaPercent: Double? {
        guard let pace14, let pace90, pace90 > 0 else { return nil }
        return (pace14 / pace90 - 1) * 100
    }

    public init(pace14: Double?, pace90: Double?) {
        self.pace14 = pace14
        self.pace90 = pace90
    }
}

/// One group in a "WPM by …" breakdown.
public struct SpeedGroup: Sendable, Equatable, Hashable, Identifiable {
    /// Book id, time band raw value, or font size formatted "%.2f".
    public var key: String
    /// Display label: book title, "Morning", or "125%".
    public var label: String
    public var wpm: Double
    public var minutes: Double
    public var id: String { key }

    public init(key: String, label: String, wpm: Double, minutes: Double) {
        self.key = key
        self.label = label
        self.wpm = wpm
        self.minutes = minutes
    }
}

/// Time-of-day bands by `local_start_hour`.
public enum TimeBand: String, CaseIterable, Sendable {
    /// 05–11
    case morning
    /// 12–16
    case afternoon
    /// 17–21
    case evening
    /// 22–04
    case night

    public var label: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    public static func band(forHour hour: Int) -> TimeBand {
        switch hour {
        case 5 ... 11: .morning
        case 12 ... 16: .afternoon
        case 17 ... 21: .evening
        default: .night
        }
    }
}

/// One paginated session's pages per minute, for the trend chart.
public struct PagesPerMinutePoint: Sendable, Equatable, Hashable {
    public var localDate: String
    public var pagesPerMinute: Double

    public init(localDate: String, pagesPerMinute: Double) {
        self.localDate = localDate
        self.pagesPerMinute = pagesPerMinute
    }
}

extension MetricsQueries {
    /// Speed groups need at least this many pace-eligible minutes to be shown.
    public static let speedGroupMinMinutes = 10.0

    public static func lifetimeTotals(_ db: Database) throws -> LifetimeTotals {
        LifetimeTotals(activeSeconds: 0, wordsRead: 0, sessions: 0, booksFinished: 0)  // TODO(Task A)
    }

    public static func paceComparison(_ db: Database, today: String) throws -> PaceComparison {
        PaceComparison(pace14: nil, pace90: nil)  // TODO(Task A)
    }

    /// Sessions in the 7 reading days ending `today`, and their median active minutes.
    public static func sessionsThisWeek(_ db: Database, today: String) throws -> (count: Int, medianMinutes: Double?) {
        (0, nil)  // TODO(Task A)
    }

    /// WPM per book over pace-eligible sessions in `[from, to]`, fastest first; books under
    /// `speedGroupMinMinutes` are left out.
    public static func wpmByBook(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        []  // TODO(Task A)
    }

    /// WPM per `TimeBand`, in `TimeBand.allCases` order, leaving out bands under the minimum.
    public static func wpmByTimeBand(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        []  // TODO(Task A)
    }

    /// WPM per font size (rounded to 2 decimals; label "125%"), smallest first; sessions without
    /// a font size are left out, as are sizes under the minimum.
    public static func wpmByFontSize(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        []  // TODO(Task A)
    }

    /// Paginated (`reading_mode = 'paginated'`) sessions in `[from, to]` with ≥ 2 active minutes
    /// and ≥ 1 page turn, oldest first: page_turns / active minutes.
    public static func pagesPerMinuteTrend(_ db: Database, from: String, to: String) throws -> [PagesPerMinutePoint] {
        []  // TODO(Task A)
    }
}
