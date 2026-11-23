import Foundation
import GRDB
import Tracking

extension Migrations {
    /// v6_goals_aggregates: `dim_goal` ✓ (SCD2), `agg_daily_reading`, `agg_book_stats` (SPEC §5.2).
    ///
    /// - `dim_goal` is synced: one TEXT UUID PK, no other UNIQUE constraint, every other column
    ///   nullable or DEFAULT, soft delete only.
    /// - `agg_*` are local and rebuildable, so a natural-key PK is fine.
    /// - Seeds one `daily_minutes` goal: target 30, `valid_from` = the earliest non-deleted session
    ///   `local_date`, else today's reading day (computed in Swift with the stored `day_start_hour`,
    ///   default 4, and `timeZone`), `valid_to` NULL.
    /// - Backfills both aggregates from the existing facts.
    ///
    /// The backfill SQL below is a frozen copy of the v6 refresh SQL, deliberately not a call into
    /// `AppDatabase.rebuildAggregates`: if the live SQL later references a column added by v7+, a
    /// fresh install running v1→v7 would otherwise fail inside v6. Never edit it once shipped.
    static func v6GoalsAggregates(_ db: Database, now: Date = Date(), timeZone: TimeZone = .current) throws {
        try db.execute(sql: """
            CREATE TABLE dim_goal (
                goal_id TEXT PRIMARY KEY NOT NULL,
                metric TEXT,
                target REAL,
                valid_from TEXT,
                valid_to TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_dim_goal_metric_valid_from ON dim_goal (metric, valid_from);

            CREATE TABLE agg_daily_reading (
                local_date TEXT PRIMARY KEY NOT NULL,
                active_minutes REAL NOT NULL DEFAULT 0,
                words_read INTEGER NOT NULL DEFAULT 0,
                sessions INTEGER NOT NULL DEFAULT 0,
                books_touched INTEGER NOT NULL DEFAULT 0,
                pace_wpm REAL,
                goal_minutes REAL,
                goal_met INTEGER NOT NULL DEFAULT 0,
                highlights_created INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE agg_book_stats (
                book_id TEXT PRIMARY KEY NOT NULL,
                total_active_minutes REAL NOT NULL DEFAULT 0,
                total_words_read INTEGER NOT NULL DEFAULT 0,
                sessions INTEGER NOT NULL DEFAULT 0,
                first_read_date TEXT,
                last_read_date TEXT,
                avg_wpm REAL,
                median_session_minutes REAL,
                highlights INTEGER NOT NULL DEFAULT 0,
                pct_complete REAL
            );
            """)

        // Raw SQL (not the live accessor): latest non-deleted day_start_hour wins.
        let storedHour = try String.fetchOne(db, sql: """
            SELECT value_json FROM app_setting
            WHERE key = 'day_start_hour' AND deleted_at IS NULL
            ORDER BY updated_at DESC
            LIMIT 1
            """).flatMap(Double.init)
        let dayStartHour = storedHour.flatMap { (0...23).contains($0) && $0 == $0.rounded() ? Int($0) : nil } ?? 4

        let earliest = try String.fetchOne(db, sql: """
            SELECT MIN(local_date) FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date IS NOT NULL
            """)
        let validFrom = earliest ?? ReadingDay.localDate(for: now, timeZone: timeZone, dayStartHour: dayStartHour)
        let nowString = Timestamp.string(from: now)
        try db.execute(
            sql: """
                INSERT INTO dim_goal (goal_id, metric, target, valid_from, valid_to, created_at, updated_at)
                VALUES (?, 'daily_minutes', 30, ?, NULL, ?, ?)
                """,
            arguments: [UUID().uuidString, validFrom, nowString, nowString])

        try v6Backfill(db, dayStartHour: dayStartHour, timeZone: timeZone)
    }

    private static func v6Backfill(_ db: Database, dayStartHour: Int, timeZone: TimeZone) throws {
        var days = try String.fetchSet(db, sql: """
            SELECT DISTINCT local_date FROM fact_reading_session
            WHERE deleted_at IS NULL AND local_date IS NOT NULL AND book_id IS NOT NULL
            """)
        for createdAt in try String.fetchSet(db, sql: """
            SELECT DISTINCT created_at FROM fact_highlight WHERE deleted_at IS NULL AND created_at IS NOT NULL
            """) {
            if let instant = Timestamp.date(from: createdAt) {
                days.insert(ReadingDay.localDate(for: instant, timeZone: timeZone, dayStartHour: dayStartHour))
            }
        }
        var windows: [[String: String]] = []
        for day in days.sorted() {
            if let w = ReadingDays.window(for: day, dayStartHour: dayStartHour, timeZone: timeZone) {
                windows.append(["d": day, "s": w.start, "e": w.end])
            }
        }
        let daysJSON = String(decoding: try JSONSerialization.data(withJSONObject: windows, options: [.sortedKeys]),
                              as: UTF8.self)

        try db.execute(sql: """
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
            """, arguments: ["days": daysJSON])

        try db.execute(sql: """
            WITH books AS (
                SELECT book_id, word_count, last_total_progression
                FROM dim_book
                WHERE deleted_at IS NULL
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
            """)
    }
}
