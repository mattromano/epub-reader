import Foundation
import GRDB
import Tracking

// Local aggregates `agg_daily_reading` / `agg_book_stats` (SPEC §5.2 "Local aggregates", §6.3–6.4),
// goals (`dim_goal`, SCD2) and the stats settings.
//
// The refresh SQL lives here, in Persistence, rather than in Metrics: every session and highlight
// write path refreshes the affected day and book inside its own write transaction, and Metrics
// depends on Persistence (not the reverse). Metrics holds the read-side queries.
extension AppDatabase {
    // MARK: - Settings

    /// `day_start_hour` (0–23, default 4). Same key the tracker config reads.
    public func dayStartHour() async throws -> Int {
        try await writer.read { db in try Self.dayStartHour(db) }
    }

    public func setDayStartHour(_ hour: Int, now: Date = Date()) async throws {
        guard (0...23).contains(hour) else { throw AppDatabaseError.invalidSetting(SettingKey.dayStartHour) }
        try await setSettingJSON(String(hour), forKey: SettingKey.dayStartHour, now: now)
    }

    /// `streak_min_minutes` (default 5): a qualifying day has at least this many active minutes.
    public func streakMinMinutes() async throws -> Double {
        try await writer.read { db in try Self.streakMinMinutes(db) }
    }

    public func setStreakMinMinutes(_ minutes: Double, now: Date = Date()) async throws {
        guard minutes >= 0, minutes.isFinite else { throw AppDatabaseError.invalidSetting(SettingKey.streakMinMinutes) }
        try await setSettingJSON(Self.jsonNumber(minutes), forKey: SettingKey.streakMinMinutes, now: now)
    }

    public static func dayStartHour(_ db: Database) throws -> Int {
        guard let hour = try settingNumber(db, key: SettingKey.dayStartHour),
              (0...23).contains(hour), hour == hour.rounded() else { return ReadingDays.defaultDayStartHour }
        return Int(hour)
    }

    public static func streakMinMinutes(_ db: Database) throws -> Double {
        guard let minutes = try settingNumber(db, key: SettingKey.streakMinMinutes), minutes >= 0 else { return 5 }
        return minutes
    }

    enum SettingKey {
        static let dayStartHour = "day_start_hour"
        static let streakMinMinutes = "streak_min_minutes"
    }

    static func settingNumber(_ db: Database, key: String) throws -> Double? {
        guard let json = try currentSetting(db, key: key)?.valueJSON, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Double.self, from: data)
    }

    private static func jsonNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    // MARK: - Goals

    /// The current goal row for `metric` (nil if none).
    public func currentGoal(_ metric: GoalMetric) async throws -> GoalRecord? {
        try await writer.read { db in try GoalRequests.current(metric).fetchOne(db) }
    }

    /// SCD2 goal change effective from reading day `localDate` (inclusive):
    /// - rows starting on or after `localDate` are soft-deleted (a same-day change never leaves an
    ///   empty `[d, d)` interval, and an earlier date never leaves a negative one);
    /// - the row spanning `localDate` gets `valid_to = localDate`;
    /// - a new open-ended row starts at `localDate`.
    /// Then `agg_daily_reading` is recomputed for every aggregated day ≥ `localDate`.
    public func setGoal(_ metric: GoalMetric, target: Double, effectiveFrom localDate: String,
                        now: Date = Date(), timeZone: TimeZone = .current) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_goal
                    SET deleted_at = :now, updated_at = :now
                    WHERE metric = :metric AND deleted_at IS NULL AND valid_from >= :from;

                    UPDATE dim_goal
                    SET valid_to = :from, updated_at = :now
                    WHERE metric = :metric AND deleted_at IS NULL AND valid_from < :from
                      AND (valid_to IS NULL OR valid_to > :from);
                    """,
                arguments: ["now": nowString, "metric": metric.rawValue, "from": localDate])
            try GoalRecord(id: UUID().uuidString, metric: metric.rawValue, target: target, validFrom: localDate,
                           validTo: nil, createdAt: nowString, updatedAt: nowString, deletedAt: nil).insert(db)

            guard metric == .dailyMinutes else { return }
            let days = try String.fetchSet(
                db, sql: "SELECT local_date FROM agg_daily_reading WHERE local_date >= ?", arguments: [localDate])
            try Self.refreshDaily(db, localDates: days, timeZone: timeZone)
        }
    }

    // MARK: - Refresh / rebuild

    /// Recomputes the given reading days and books from the facts, in one write transaction.
    public func refreshAggregates(localDates: Set<String>, bookIDs: Set<String>,
                                  timeZone: TimeZone = .current) async throws {
        try await writer.write { db in
            try Self.refreshAggregates(db, localDates: localDates, bookIDs: bookIDs, timeZone: timeZone)
        }
    }

    /// Database-level refresh, for use inside an existing write transaction. Deletes then
    /// re-inserts the target rows, so a day or book with no remaining facts loses its row.
    /// `timeZone` and the stored `day_start_hour` bucket highlights (which only store a UTC
    /// `created_at`) into reading days.
    public static func refreshAggregates(_ db: Database, localDates: Set<String>, bookIDs: Set<String>,
                                         timeZone: TimeZone = .current) throws {
        try refreshDaily(db, localDates: localDates, timeZone: timeZone)
        try refreshBooks(db, bookIDs: bookIDs)
    }

    /// Deletes every aggregate row and recomputes everything ("Rebuild stats").
    public func rebuildAggregates(timeZone: TimeZone = .current) async throws {
        try await writer.write { db in
            try Self.rebuildAggregates(db, timeZone: timeZone)
        }
    }

    public static func rebuildAggregates(_ db: Database, timeZone: TimeZone = .current) throws {
        try db.execute(sql: "DELETE FROM agg_daily_reading; DELETE FROM agg_book_stats;")
        let dayStartHour = try dayStartHour(db)
        var days = try String.fetchSet(db, sql: """
            SELECT DISTINCT local_date
            FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date IS NOT NULL AND book_id IS NOT NULL
            """)
        let highlightTimes = try String.fetchSet(db, sql: """
            SELECT DISTINCT created_at FROM fact_highlight WHERE deleted_at IS NULL AND created_at IS NOT NULL
            """)
        for createdAt in highlightTimes {
            if let day = readingDay(ofTimestamp: createdAt, dayStartHour: dayStartHour, timeZone: timeZone) {
                days.insert(day)
            }
        }
        let books = try String.fetchSet(db, sql: "SELECT book_id FROM dim_book WHERE deleted_at IS NULL")
        try refreshDaily(db, localDates: days, timeZone: timeZone)
        try refreshBooks(db, bookIDs: books)
    }

    /// The reading day of a stored UTC timestamp.
    static func readingDay(ofTimestamp timestamp: String, dayStartHour: Int, timeZone: TimeZone) -> String? {
        Timestamp.date(from: timestamp).map {
            ReadingDay.localDate(for: $0, timeZone: timeZone, dayStartHour: dayStartHour)
        }
    }

    private struct DayWindow: Encodable {
        var d: String
        var s: String
        var e: String
    }

    /// `[{d, s, e}]`: each target day with its UTC `[start, end)` window, bound as one JSON parameter.
    private static func dayWindowsJSON(_ localDates: Set<String>, dayStartHour: Int,
                                       timeZone: TimeZone) throws -> String {
        let windows = localDates.sorted().compactMap { day -> DayWindow? in
            guard let w = ReadingDays.window(for: day, dayStartHour: dayStartHour, timeZone: timeZone) else {
                return nil
            }
            return DayWindow(d: day, s: w.start, e: w.end)
        }
        return String(decoding: try JSONEncoder().encode(windows), as: UTF8.self)
    }

    private static func jsonArray(_ values: Set<String>) throws -> String {
        String(decoding: try JSONEncoder().encode(values.sorted()), as: UTF8.self)
    }

    static func refreshDaily(_ db: Database, localDates: Set<String>, timeZone: TimeZone) throws {
        guard !localDates.isEmpty else { return }
        let days = try dayWindowsJSON(localDates, dayStartHour: try dayStartHour(db), timeZone: timeZone)
        try db.execute(sql: """
            WITH target_days AS (
                SELECT json_extract(value, '$.d') AS local_date
                FROM json_each(:days)
            )
            DELETE FROM agg_daily_reading WHERE local_date IN target_days
            """, arguments: ["days": days])
        try db.execute(sql: dailyRefreshSQL, arguments: ["days": days])
    }

    static func refreshBooks(_ db: Database, bookIDs: Set<String>) throws {
        guard !bookIDs.isEmpty else { return }
        let books = try jsonArray(bookIDs)
        try db.execute(sql: """
            WITH target_books AS (
                SELECT value AS book_id FROM json_each(:books)
            )
            DELETE FROM agg_book_stats WHERE book_id IN target_books
            """, arguments: ["books": books])
        try db.execute(sql: bookRefreshSQL, arguments: ["books": books])
    }

    /// SPEC §6.4 daily rollup with the SCD2 goal join, for the bound target days.
    /// - Sessions: non-deleted, `local_date` = the day (sessions without a book or date are ignored).
    /// - Highlights: non-deleted, `created_at` inside the day's UTC window (computed in Swift).
    /// - A day gets a row if it has a session or a highlight; highlight-only days have 0 minutes.
    /// - Goal: the non-deleted `daily_minutes` row valid on the day; if sync delivered overlapping
    ///   rows, the latest `valid_from` (then `updated_at`) wins, so the join never fans out.
    /// - `pace_wpm`: ratio of sums over pace-eligible sessions (SPEC §6.3 Pace WPM).
    static let dailyRefreshSQL = """
        WITH target_days AS (
            SELECT json_extract(value, '$.d') AS local_date,
                   json_extract(value, '$.s') AS window_start,
                   json_extract(value, '$.e') AS window_end
            FROM json_each(:days)
        ),
        sessions AS (
            SELECT s.local_date, s.book_id, s.active_seconds, s.words_read, s.is_pace_eligible
            FROM fact_reading_session AS s
            JOIN target_days AS t ON t.local_date = s.local_date
            WHERE s.deleted_at IS NULL AND s.book_id IS NOT NULL
        ),
        daily AS (
            SELECT local_date,
                   SUM(active_seconds) / 60.0 AS active_minutes,
                   SUM(words_read) AS words_read,
                   COUNT(*) AS sessions,
                   COUNT(DISTINCT book_id) AS books_touched,
                   SUM(CASE WHEN is_pace_eligible = 1 THEN words_read END) * 60.0
                     / NULLIF(SUM(CASE WHEN is_pace_eligible = 1 THEN active_seconds END), 0) AS pace_wpm
            FROM sessions
            GROUP BY local_date
        ),
        highlights AS (
            SELECT t.local_date, COUNT(*) AS highlights_created
            FROM fact_highlight AS h
            JOIN target_days AS t ON h.created_at >= t.window_start AND h.created_at < t.window_end
            WHERE h.deleted_at IS NULL
            GROUP BY t.local_date
        ),
        days AS (
            SELECT t.local_date,
                   COALESCE(d.active_minutes, 0) AS active_minutes,
                   COALESCE(d.words_read, 0) AS words_read,
                   COALESCE(d.sessions, 0) AS sessions,
                   COALESCE(d.books_touched, 0) AS books_touched,
                   d.pace_wpm,
                   COALESCE(h.highlights_created, 0) AS highlights_created
            FROM target_days AS t
            LEFT JOIN daily AS d ON d.local_date = t.local_date
            LEFT JOIN highlights AS h ON h.local_date = t.local_date
            WHERE d.local_date IS NOT NULL OR h.local_date IS NOT NULL
        ),
        goals AS (
            SELECT target, valid_from, COALESCE(valid_to, '9999-12-31') AS valid_to, updated_at
            FROM dim_goal
            WHERE metric = 'daily_minutes' AND deleted_at IS NULL
        ),
        day_goals AS (
            SELECT dy.local_date, g.target,
                   ROW_NUMBER() OVER (PARTITION BY dy.local_date
                                      ORDER BY g.valid_from DESC, g.updated_at DESC) AS rn
            FROM days AS dy
            JOIN goals AS g ON dy.local_date >= g.valid_from AND dy.local_date < g.valid_to
        )
        INSERT INTO agg_daily_reading (local_date, active_minutes, words_read, sessions, books_touched,
                                       pace_wpm, goal_minutes, goal_met, highlights_created)
        SELECT dy.local_date, dy.active_minutes, dy.words_read, dy.sessions, dy.books_touched, dy.pace_wpm,
               dg.target,
               CASE WHEN dg.target IS NOT NULL AND dy.active_minutes >= dg.target THEN 1 ELSE 0 END,
               dy.highlights_created
        FROM days AS dy
        LEFT JOIN day_goals AS dg ON dg.local_date = dy.local_date AND dg.rn = 1
        """

    /// Per-book stats for the bound book ids (non-deleted books only; every such book gets a row).
    /// - `avg_wpm`: ratio of sums over pace-eligible sessions (SPEC §6.3 Book pace numerator).
    /// - `median_session_minutes`: median `active_seconds` / 60 (SPEC §6.3 Avg session length).
    /// - `pct_complete`: max `end_word_idx` reached ÷ `dim_book.word_count`, clamped to [0, 1],
    ///   when the book is indexed and a session recorded a word index; otherwise the stored
    ///   Readium `last_total_progression` (SPEC §6.3 % complete: words, not bytes).
    static let bookRefreshSQL = """
        WITH target_books AS (
            SELECT value AS book_id FROM json_each(:books)
        ),
        books AS (
            SELECT b.book_id, b.word_count, b.last_total_progression
            FROM dim_book AS b
            JOIN target_books AS t ON t.book_id = b.book_id
            WHERE b.deleted_at IS NULL
        ),
        sessions AS (
            SELECT s.book_id, s.local_date, s.active_seconds, s.words_read, s.is_pace_eligible, s.end_word_idx
            FROM fact_reading_session AS s
            JOIN books AS b ON b.book_id = s.book_id
            WHERE s.deleted_at IS NULL AND s.local_date IS NOT NULL
        ),
        totals AS (
            SELECT book_id,
                   SUM(active_seconds) / 60.0 AS total_active_minutes,
                   SUM(words_read) AS total_words_read,
                   COUNT(*) AS sessions,
                   MIN(local_date) AS first_read_date,
                   MAX(local_date) AS last_read_date,
                   SUM(CASE WHEN is_pace_eligible = 1 THEN words_read END) * 60.0
                     / NULLIF(SUM(CASE WHEN is_pace_eligible = 1 THEN active_seconds END), 0) AS avg_wpm,
                   MAX(end_word_idx) AS max_word_idx
            FROM sessions
            GROUP BY book_id
        ),
        ranked AS (
            SELECT book_id, active_seconds,
                   ROW_NUMBER() OVER (PARTITION BY book_id ORDER BY active_seconds) AS rn,
                   COUNT(*) OVER (PARTITION BY book_id) AS n
            FROM sessions
        ),
        medians AS (
            SELECT book_id, AVG(active_seconds) / 60.0 AS median_session_minutes
            FROM ranked
            WHERE rn IN ((n + 1) / 2, (n + 2) / 2)
            GROUP BY book_id
        ),
        highlights AS (
            SELECT h.book_id, COUNT(*) AS highlights
            FROM fact_highlight AS h
            JOIN books AS b ON b.book_id = h.book_id
            WHERE h.deleted_at IS NULL
            GROUP BY h.book_id
        )
        INSERT INTO agg_book_stats (book_id, total_active_minutes, total_words_read, sessions, first_read_date,
                                    last_read_date, avg_wpm, median_session_minutes, highlights, pct_complete)
        SELECT b.book_id,
               COALESCE(t.total_active_minutes, 0),
               COALESCE(t.total_words_read, 0),
               COALESCE(t.sessions, 0),
               t.first_read_date,
               t.last_read_date,
               t.avg_wpm,
               m.median_session_minutes,
               COALESCE(h.highlights, 0),
               CASE WHEN b.word_count > 0 AND t.max_word_idx IS NOT NULL
                    THEN MIN(1.0, MAX(0.0, t.max_word_idx * 1.0 / b.word_count))
                    ELSE COALESCE(b.last_total_progression, 0) END
        FROM books AS b
        LEFT JOIN totals AS t ON t.book_id = b.book_id
        LEFT JOIN medians AS m ON m.book_id = b.book_id
        LEFT JOIN highlights AS h ON h.book_id = b.book_id
        """
}
