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

    /// Stats-tab design, Overview "Lifetime strip": sums over every non-deleted session, plus the
    /// non-deleted books with status `finished`.
    public static func lifetimeTotals(_ db: Database) throws -> LifetimeTotals {
        guard let row = try Row.fetchOne(db, sql: lifetimeTotalsSQL) else {
            return LifetimeTotals(activeSeconds: 0, wordsRead: 0, sessions: 0, booksFinished: 0)
        }
        return LifetimeTotals(activeSeconds: row["active_seconds"], wordsRead: row["words_read"],
                              sessions: row["sessions"], booksFinished: row["books_finished"])
    }

    static let lifetimeTotalsSQL = """
        WITH session_totals AS (
            SELECT COALESCE(SUM(active_seconds), 0) AS active_seconds,
                   COALESCE(SUM(words_read), 0) AS words_read,
                   COUNT(*) AS sessions
            FROM fact_reading_session
            WHERE deleted_at IS NULL
        ),
        finished_books AS (
            SELECT COUNT(*) AS books_finished
            FROM dim_book
            WHERE deleted_at IS NULL AND status = 'finished'
        )
        SELECT t.active_seconds, t.words_read, t.sessions, b.books_finished
        FROM session_totals t
        CROSS JOIN finished_books b
        """

    /// Stats-tab design, Overview "Today card": ratio-of-sums pace over pace-eligible sessions in
    /// `[today−13, today]` and `[today−89, today]`; nil where the window has no eligible seconds.
    public static func paceComparison(_ db: Database, today: String) throws -> PaceComparison {
        let row = try Row.fetchOne(db, sql: paceComparisonSQL, arguments: [
            "today": today,
            "start14": try shift(today, by: -13),
            "start90": try shift(today, by: -89),
        ])
        return PaceComparison(pace14: row?["pace_14"], pace90: row?["pace_90"])
    }

    static let paceComparisonSQL = """
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
        SELECT words_14 * 60.0 / NULLIF(seconds_14, 0) AS pace_14,
               words_90 * 60.0 / NULLIF(seconds_90, 0) AS pace_90
        FROM windows
        """

    /// Sessions in the 7 reading days ending `today`, and their median active minutes.
    public static func sessionsThisWeek(_ db: Database, today: String) throws -> (count: Int, medianMinutes: Double?) {
        let row = try Row.fetchOne(db, sql: sessionsThisWeekSQL, arguments: [
            "today": today, "start": try shift(today, by: -6),
        ])
        return (row?["sessions"] ?? 0, row?["median_minutes"])
    }

    /// Stats-tab design, Sessions nav card: count and median minutes over the last 7 reading days.
    /// The median is the middle value, or the mean of the middle two for an even count.
    static let sessionsThisWeekSQL = """
        WITH week AS (
            SELECT active_seconds / 60.0 AS minutes
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date BETWEEN :start AND :today
        ),
        ranked AS (
            SELECT minutes,
                   ROW_NUMBER() OVER (ORDER BY minutes) AS rn,
                   COUNT(*) OVER () AS n
            FROM week
        )
        SELECT COUNT(*) AS sessions,
               AVG(CASE WHEN rn IN ((n + 1) / 2, (n + 2) / 2) THEN minutes END) AS median_minutes
        FROM ranked
        """

    private static func speedArguments(_ from: String, _ to: String) -> StatementArguments {
        ["from": from, "to": to, "min_seconds": speedGroupMinMinutes * 60]
    }

    /// WPM per book over pace-eligible sessions in `[from, to]`, fastest first; books under
    /// `speedGroupMinMinutes` are left out.
    public static func wpmByBook(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        try Row.fetchAll(db, sql: wpmByBookSQL, arguments: speedArguments(from, to)).map {
            SpeedGroup(key: $0["key"], label: $0["label"], wpm: $0["wpm"], minutes: $0["minutes"])
        }
    }

    /// Stats-tab design, Speed "WPM by book": ratio of sums per non-deleted book; fastest first,
    /// ties by more minutes.
    static let wpmByBookSQL = """
        WITH eligible AS (
            SELECT s.book_id, s.words_read, s.active_seconds
            FROM fact_reading_session s
            JOIN dim_book b ON b.book_id = s.book_id AND b.deleted_at IS NULL
            WHERE s.deleted_at IS NULL AND s.is_pace_eligible = 1
              AND s.local_date BETWEEN :from AND :to
        ),
        grouped AS (
            SELECT book_id, SUM(words_read) AS words, SUM(active_seconds) AS seconds
            FROM eligible
            GROUP BY book_id
        )
        SELECT g.book_id AS key, b.title AS label,
               g.words * 60.0 / g.seconds AS wpm, g.seconds / 60.0 AS minutes
        FROM grouped g
        JOIN dim_book b ON b.book_id = g.book_id
        WHERE g.seconds >= :min_seconds
        ORDER BY wpm DESC, minutes DESC, key
        """

    /// WPM per `TimeBand`, in `TimeBand.allCases` order, leaving out bands under the minimum.
    public static func wpmByTimeBand(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        let order = Dictionary(uniqueKeysWithValues: TimeBand.allCases.enumerated().map { ($1.rawValue, $0) })
        return try Row.fetchAll(db, sql: wpmByTimeBandSQL, arguments: speedArguments(from, to))
            .compactMap { row -> (Int, SpeedGroup)? in
                guard let band = TimeBand(rawValue: row["key"]), let rank = order[band.rawValue] else { return nil }
                return (rank, SpeedGroup(key: band.rawValue, label: band.label, wpm: row["wpm"], minutes: row["minutes"]))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// Stats-tab design, Speed "WPM by time band". The `CASE` mirrors `TimeBand.band(forHour:)`:
    /// morning 05–11, afternoon 12–16, evening 17–21, night 22–04. NULL hours are left out.
    static let wpmByTimeBandSQL = """
        WITH eligible AS (
            SELECT CASE WHEN local_start_hour BETWEEN 5 AND 11 THEN 'morning'
                        WHEN local_start_hour BETWEEN 12 AND 16 THEN 'afternoon'
                        WHEN local_start_hour BETWEEN 17 AND 21 THEN 'evening'
                        ELSE 'night' END AS band,
                   words_read, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND is_pace_eligible = 1 AND book_id IS NOT NULL
              AND local_start_hour IS NOT NULL AND local_date BETWEEN :from AND :to
        ),
        grouped AS (
            SELECT band, SUM(words_read) AS words, SUM(active_seconds) AS seconds
            FROM eligible
            GROUP BY band
        )
        SELECT band AS key, words * 60.0 / seconds AS wpm, seconds / 60.0 AS minutes
        FROM grouped
        WHERE seconds >= :min_seconds
        """

    /// WPM per font size (rounded to 2 decimals; label "125%"), smallest first; sessions without
    /// a font size are left out, as are sizes under the minimum.
    public static func wpmByFontSize(_ db: Database, from: String, to: String) throws -> [SpeedGroup] {
        try Row.fetchAll(db, sql: wpmByFontSizeSQL, arguments: speedArguments(from, to)).map { row in
            let size: Double = row["size"]
            return SpeedGroup(key: String(format: "%.2f", size), label: "\(Int((size * 100).rounded()))%",
                              wpm: row["wpm"], minutes: row["minutes"])
        }
    }

    /// Stats-tab design, Speed "WPM by font size".
    static let wpmByFontSizeSQL = """
        WITH eligible AS (
            SELECT ROUND(font_size, 2) AS size, words_read, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND is_pace_eligible = 1 AND book_id IS NOT NULL
              AND font_size IS NOT NULL AND local_date BETWEEN :from AND :to
        ),
        grouped AS (
            SELECT size, SUM(words_read) AS words, SUM(active_seconds) AS seconds
            FROM eligible
            GROUP BY size
        )
        SELECT size, words * 60.0 / seconds AS wpm, seconds / 60.0 AS minutes
        FROM grouped
        WHERE seconds >= :min_seconds
        ORDER BY size
        """

    /// Paginated (`reading_mode = 'paginated'`) sessions in `[from, to]` with ≥ 2 active minutes
    /// and ≥ 1 page turn, oldest first: page_turns / active minutes.
    public static func pagesPerMinuteTrend(_ db: Database, from: String, to: String) throws -> [PagesPerMinutePoint] {
        try Row.fetchAll(db, sql: pagesPerMinuteSQL, arguments: ["from": from, "to": to]).map {
            PagesPerMinutePoint(localDate: $0["local_date"], pagesPerMinute: $0["pages_per_minute"])
        }
    }

    /// Stats-tab design, Speed "Pages/min trend".
    static let pagesPerMinuteSQL = """
        WITH paginated AS (
            SELECT local_date, started_at, page_turns, active_seconds
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND reading_mode = 'paginated'
              AND active_seconds >= 120 AND page_turns >= 1
              AND local_date BETWEEN :from AND :to
        )
        SELECT local_date, page_turns * 60.0 / active_seconds AS pages_per_minute
        FROM paginated
        ORDER BY local_date, started_at
        """
}
