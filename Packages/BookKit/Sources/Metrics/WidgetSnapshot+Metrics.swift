import Foundation
import GRDB
import Persistence
import WidgetData

extension MetricsQueries {
    /// The book the widget offers to continue: the most recently opened (else most recently
    /// read) live book that isn't finished or abandoned, with its furthest word position from the
    /// latest session (for time left) and `agg_book_stats.pct_complete`.
    static let continueReadingSQL = """
        WITH latest_session AS (
            SELECT book_id, MAX(ended_at) AS last_session_at
            FROM fact_reading_session
            WHERE deleted_at IS NULL
            GROUP BY book_id
        ),
        candidates AS (
            SELECT b.book_id, b.title, b.authors, b.cover_relpath, b.last_total_progression,
                   COALESCE(b.last_opened_at, l.last_session_at) AS last_activity_at
            FROM dim_book AS b
            LEFT JOIN latest_session AS l ON l.book_id = b.book_id
            WHERE b.deleted_at IS NULL
              AND b.status NOT IN ('finished', 'abandoned')
              AND COALESCE(b.last_opened_at, l.last_session_at) IS NOT NULL
        ),
        chosen AS (
            SELECT book_id, title, authors, cover_relpath, last_total_progression
            FROM candidates
            ORDER BY last_activity_at DESC
            LIMIT 1
        ),
        last_position AS (
            SELECT s.book_id, s.end_word_idx
            FROM fact_reading_session AS s
            JOIN chosen AS c ON c.book_id = s.book_id
            WHERE s.deleted_at IS NULL AND s.end_word_idx IS NOT NULL
            ORDER BY s.ended_at DESC
            LIMIT 1
        )
        SELECT c.book_id, c.title, c.authors, c.cover_relpath, c.last_total_progression,
               st.pct_complete, p.end_word_idx
        FROM chosen AS c
        LEFT JOIN agg_book_stats AS st ON st.book_id = c.book_id
        LEFT JOIN last_position AS p ON p.book_id = c.book_id
        """

    /// Everything the widget needs, computed from the aggregates (PLAN M6). The app writes it to
    /// `widget_snapshot.json` after each session and on backgrounding.
    public static func widgetSnapshot(_ db: Database, now: Date = Date(),
                                      timeZone: TimeZone = .current) throws -> WidgetSnapshot {
        let dayStartHour = try AppDatabase.dayStartHour(db)
        let minMinutes = try AppDatabase.streakMinMinutes(db)
        let today = ReadingDays.today(now: now, dayStartHour: dayStartHour, timeZone: timeZone)
        let todayRow = try daily(db, from: today, to: today).first
        let goal = try GoalRequests.current(.dailyMinutes).fetchOne(db)?.target
        let streak = try streaks(db, today: today, minMinutes: minMinutes)

        var continueReading: WidgetSnapshot.ContinueReading?
        if let row = try Row.fetchOne(db, sql: continueReadingSQL) {
            let bookID: String = row["book_id"]
            let endWordIdx: Int? = row["end_word_idx"]
            let minutesLeft = try endWordIdx.flatMap {
                try timeLeft(db, bookID: bookID, chapterID: nil, currentWordIdx: $0, today: today).bookMinutes
            }
            let pct: Double? = row["pct_complete"]
            let fallback: Double? = row["last_total_progression"]
            continueReading = .init(bookID: bookID, title: row["title"] ?? "", authors: row["authors"] ?? "",
                                    coverRelpath: row["cover_relpath"], percentComplete: pct ?? fallback,
                                    bookMinutesLeft: minutesLeft)
        }

        return WidgetSnapshot(
            generatedAt: now, today: today, dayStartHour: dayStartHour, timeZoneID: timeZone.identifier,
            todayMinutes: todayRow?.activeMinutes ?? 0, goalMinutes: goal, streakMinMinutes: minMinutes,
            currentStreak: streak.current, streakIncludesToday: streak.currentIncludesToday,
            continueReading: continueReading)
    }
}
