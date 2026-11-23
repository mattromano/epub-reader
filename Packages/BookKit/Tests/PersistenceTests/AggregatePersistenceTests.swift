import Foundation
import GRDB
import Importing
import Testing
import Tracking
@testable import Persistence

// M5 Session A: v6_goals_aggregates, dim_goal (SCD2), agg_* refresh/rebuild (SPEC §5.2, §6.3).

private let utc = TimeZone(identifier: "UTC")!

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

/// A session on `localDate` starting at `hour`:00 UTC.
private func row(_ id: String, book: String, localDate: String, minutes: Double, words: Int,
                 eligible: Bool = true, hour: Int = 12, endWordIdx: Int? = nil) -> SessionRow {
    let start = date("\(localDate)T\(String(format: "%02d", hour)):00:00.000Z")
    return SessionRow(sessionID: id, bookID: book, deviceID: "device-1", startedAt: start,
                      endedAt: start.addingTimeInterval(minutes * 60), localDate: localDate,
                      localStartHour: hour, tzOffsetMinutes: 0, wallSeconds: minutes * 60,
                      activeSeconds: minutes * 60, startWordIdx: 0, endWordIdx: endWordIdx,
                      wordsRead: words, startTotalProgression: 0, endTotalProgression: 0.1,
                      startLocatorJSON: "{}", endLocatorJSON: "{}", pageTurns: 5, jumpCount: 0,
                      readingMode: "paginated", fontSize: 1, endReason: .closed, isPaceEligible: eligible)
}

private func addBook(_ db: AppDatabase, _ hash: String) async throws -> String {
    let result = try await db.importBook(NewBook(contentHash: hash, title: hash, authors: "A",
                                                 fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1))
    guard case .inserted(let book) = result else { throw CancellationError() }
    return book.id
}

private struct AggSnapshot: Equatable {
    var daily: [Row]
    var books: [Row]
}

private func snapshot(_ db: AppDatabase) throws -> AggSnapshot {
    try db.reader.read { db in
        AggSnapshot(
            daily: try Row.fetchAll(db, sql: "SELECT * FROM agg_daily_reading ORDER BY local_date"),
            books: try Row.fetchAll(db, sql: "SELECT * FROM agg_book_stats ORDER BY book_id"))
    }
}

private func dailyRow(_ db: AppDatabase, _ localDate: String) throws -> Row? {
    try db.reader.read { db in
        try Row.fetchOne(db, sql: "SELECT * FROM agg_daily_reading WHERE local_date = ?", arguments: [localDate])
    }
}

private func bookRow(_ db: AppDatabase, _ bookID: String) throws -> Row? {
    try db.reader.read { db in
        try Row.fetchOne(db, sql: "SELECT * FROM agg_book_stats WHERE book_id = ?", arguments: [bookID])
    }
}

private func goals(_ db: AppDatabase, includeDeleted: Bool = false) throws -> [GoalRecord] {
    try db.reader.read { db in
        var request = GoalRecord.order(GoalRecord.Columns.validFrom.asc)
        if !includeDeleted { request = request.filter(GoalRecord.Columns.deletedAt == nil) }
        return try request.fetchAll(db)
    }
}

@Suite struct GoalsAggregatesMigrationTests {
    private func columns(_ db: AppDatabase, _ table: String) throws -> [String] {
        try db.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        }
    }

    @Test func v6Columns() throws {
        let db = try AppDatabase.inMemory()
        #expect(try columns(db, "dim_goal") == [
            "goal_id", "metric", "target", "valid_from", "valid_to", "created_at", "updated_at", "deleted_at",
        ])
        #expect(try columns(db, "agg_daily_reading") == [
            "local_date", "active_minutes", "words_read", "sessions", "books_touched", "pace_wpm",
            "goal_minutes", "goal_met", "highlights_created",
        ])
        #expect(try columns(db, "agg_book_stats") == [
            "book_id", "total_active_minutes", "total_words_read", "sessions", "first_read_date",
            "last_read_date", "avg_wpm", "median_session_minutes", "highlights", "pct_complete",
        ])
    }

    /// dim_goal is synced: one TEXT PK, no UNIQUE index, every other column nullable or DEFAULT.
    @Test func dimGoalFollowsSyncedTableRules() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(dim_goal)")
            #expect(rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String } == ["goal_id"])
            for row in rows where (row["name"] as String) != "goal_id" {
                let nullable = (row["notnull"] as Int) == 0
                let defaulted = (row["dflt_value"] as String?) != nil
                #expect(nullable || defaulted, "\(row["name"] as String)")
            }
            let unique = try Row.fetchAll(db, sql: "PRAGMA index_list(dim_goal)")
                .filter { ($0["unique"] as Int) == 1 && ($0["origin"] as String) != "pk" }
            #expect(unique.isEmpty)
        }
    }

    /// Empty DB: one daily_minutes goal, target 30, valid_from = today's reading day, open-ended.
    @Test func seedsDefaultGoalOnEmptyDatabase() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5_highlight_search")
        // 2026-11-22T03:00Z in UTC with day start 4 is still reading day 2026-11-21.
        try queue.write { db in
            try Migrations.v6GoalsAggregates(db, now: date("2026-11-22T03:00:00.000Z"), timeZone: utc)
        }
        let rows = try queue.read { db in try GoalRecord.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.metric == GoalMetric.dailyMinutes.rawValue)
        #expect(rows.first?.target == 30)
        #expect(rows.first?.validFrom == "2026-11-21")
        #expect(rows.first?.validTo == nil)
        #expect(rows.first?.deletedAt == nil)
    }

    /// The stored day_start_hour setting is honoured when computing "today" for the seed.
    @Test func seedTodayUsesStoredDayStartHour() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5_highlight_search")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting (setting_id, key, value_json, created_at, updated_at)
                VALUES ('s1', 'day_start_hour', '0', '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """)
            try Migrations.v6GoalsAggregates(db, now: date("2026-11-22T03:00:00.000Z"), timeZone: utc)
        }
        let validFrom = try queue.read { db in try String.fetchOne(db, sql: "SELECT valid_from FROM dim_goal") }
        #expect(validFrom == "2026-11-22")
    }

    /// v6 on a DB with sessions: the goal starts at the earliest non-deleted session's local_date,
    /// and the aggregates are backfilled, equal to a full rebuild.
    @Test func backfillsFromExistingSessions() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5_highlight_search")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO dim_book (book_id, content_hash, title, word_count, created_at, updated_at)
                VALUES ('b1', 'h1', 'One', 1000, '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z')
                """)
            let deleted = SessionRecord(row("s0", book: "b1", localDate: "2026-11-01", minutes: 10, words: 100),
                                        now: "2026-11-01T13:00:00.000Z")
            var deletedCopy = deleted
            deletedCopy.deletedAt = "2026-11-02T00:00:00.000Z"
            try deletedCopy.insert(db)
            try SessionRecord(row("s1", book: "b1", localDate: "2026-11-10", minutes: 30, words: 6000,
                                  endWordIdx: 400), now: "x").insert(db)
            try SessionRecord(row("s2", book: "b1", localDate: "2026-11-12", minutes: 10, words: 1000,
                                  endWordIdx: 500), now: "x").insert(db)
            try SessionRecord(row("s3", book: "b1", localDate: "2026-11-12", minutes: 5, words: 900),
                              now: "x").insert(db)
        }
        let db = try AppDatabase(queue)  // runs v6 with the real clock; the seed uses session dates

        let rows = try goals(db)
        #expect(rows.count == 1)
        #expect(rows.first?.validFrom == "2026-11-10")  // the deleted 11-01 session is ignored
        #expect(rows.first?.target == 30)

        // 11-10: 30 min ≥ 30 → goal met. 11-12: 15 min, pace = 1900 words / 15 min.
        let d10 = try #require(try dailyRow(db, "2026-11-10"))
        #expect(d10["active_minutes"] as Double == 30)
        #expect(d10["goal_met"] as Int == 1)
        let d12 = try #require(try dailyRow(db, "2026-11-12"))
        #expect(d12["sessions"] as Int == 2)
        #expect(abs((d12["pace_wpm"] as Double) - 1900.0 / 15.0) < 1e-9)
        #expect(try dailyRow(db, "2026-11-01") == nil)
        let b1 = try #require(try bookRow(db, "b1"))
        #expect(b1["sessions"] as Int == 3)
        #expect(b1["pct_complete"] as Double == 0.5)  // max end_word_idx 500 / 1000

        let migrated = try snapshot(db)
        try await db.rebuildAggregates(timeZone: .current)
        #expect(try snapshot(db) == migrated)
    }

    @Test func migrationListIncludesV6() throws {
        let db = try AppDatabase.inMemory()
        let applied = try db.reader.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(applied.contains("v6_goals_aggregates"))
    }
}

@Suite struct GoalSCD2Tests {
    @Test func setGoalClosesCurrentRowAndOpensNewOne() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setGoal(.dailyMinutes, target: 30, effectiveFrom: "2026-11-01", now: date("2026-11-01T12:00:00.000Z"))
        try await db.setGoal(.dailyMinutes, target: 20, effectiveFrom: "2026-11-18", now: date("2026-11-18T12:00:00.000Z"))
        let rows = try goals(db)
        #expect(rows.map(\.validFrom) == ["2026-11-01", "2026-11-18"])
        #expect(rows.map(\.validTo) == ["2026-11-18", nil])
        #expect(rows.map(\.target) == [30, 20])
        let current = try await db.currentGoal(.dailyMinutes)
        #expect(current?.target == 20)
    }

    /// Changing the goal twice on the same day must not leave an empty [d, d) interval.
    @Test func sameDayChangeSoftDeletesInsteadOfEmptyInterval() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setGoal(.dailyMinutes, target: 30, effectiveFrom: "2026-11-01")
        try await db.setGoal(.dailyMinutes, target: 45, effectiveFrom: "2026-11-01")
        let live = try goals(db)
        #expect(live.count == 1)
        #expect(live.first?.target == 45)
        #expect(live.first?.validTo == nil)
        let all = try goals(db, includeDeleted: true)
        #expect(all.allSatisfy { $0.validTo != $0.validFrom })
    }

    /// effectiveFrom before the current row's valid_from: later rows are soft-deleted, the row
    /// spanning the date is closed, and no negative interval is produced.
    @Test func earlierEffectiveDateNeverMakesNegativeInterval() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setGoal(.dailyMinutes, target: 30, effectiveFrom: "2026-10-01")
        try await db.setGoal(.dailyMinutes, target: 20, effectiveFrom: "2026-11-18")
        try await db.setGoal(.dailyMinutes, target: 25, effectiveFrom: "2026-11-05")
        let rows = try goals(db)
        #expect(rows.map(\.validFrom) == ["2026-10-01", "2026-11-05"])
        #expect(rows.map(\.validTo) == ["2026-11-05", nil])
        #expect(rows.map(\.target) == [30, 25])
    }

    @Test func goalChangeRefreshesDaysFromEffectiveDate() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "h1")
        try await db.setGoal(.dailyMinutes, target: 30, effectiveFrom: "2026-11-01")
        try await db.finishSession(row("s1", book: book, localDate: "2026-11-17", minutes: 25, words: 100), timeZone: utc)
        try await db.finishSession(row("s2", book: book, localDate: "2026-11-18", minutes: 25, words: 100), timeZone: utc)
        #expect(try dailyRow(db, "2026-11-18")?["goal_met"] as Int? == 0)
        try await db.setGoal(.dailyMinutes, target: 20, effectiveFrom: "2026-11-18", timeZone: utc)
        // 11-17 is judged against the old 30 (25 < 30), 11-18 against the new 20 (25 ≥ 20).
        #expect(try dailyRow(db, "2026-11-17")?["goal_minutes"] as Double? == 30)
        #expect(try dailyRow(db, "2026-11-17")?["goal_met"] as Int? == 0)
        #expect(try dailyRow(db, "2026-11-18")?["goal_minutes"] as Double? == 20)
        #expect(try dailyRow(db, "2026-11-18")?["goal_met"] as Int? == 1)
    }

    /// Overlapping rows (possible via sync, no UNIQUE constraint) must not fan out the daily join.
    @Test func overlappingGoalRowsPickOnePerDay() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "h1")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE dim_goal SET deleted_at = 'x'")
            try db.execute(sql: """
                INSERT INTO dim_goal (goal_id, metric, target, valid_from, valid_to, created_at, updated_at)
                VALUES ('g1', 'daily_minutes', 30, '2026-11-01', NULL, 'a', '2026-11-01T00:00:00.000Z'),
                       ('g2', 'daily_minutes', 10, '2026-11-10', NULL, 'a', '2026-11-10T00:00:00.000Z')
                """)
        }
        try await db.finishSession(row("s1", book: book, localDate: "2026-11-12", minutes: 15, words: 100), timeZone: utc)
        // The later-starting row wins: 15 ≥ 10.
        #expect(try dailyRow(db, "2026-11-12")?["goal_minutes"] as Double? == 10)
        #expect(try dailyRow(db, "2026-11-12")?["goal_met"] as Int? == 1)
    }
}

@Suite struct AggregateRefreshTests {
    /// Every write path keeps the aggregates equal to a full rebuild.
    @Test func incrementalRefreshEqualsRebuild() async throws {
        let db = try AppDatabase.inMemory()
        let b1 = try await addBook(db, "h1")
        let b2 = try await addBook(db, "h2")
        try await db.setGoal(.dailyMinutes, target: 20, effectiveFrom: "2026-11-01", timeZone: utc)
        try await db.finishSession(row("s1", book: b1, localDate: "2026-11-10", minutes: 30, words: 6000), timeZone: utc)
        try await db.finishSession(row("s2", book: b2, localDate: "2026-11-10", minutes: 12, words: 2400), timeZone: utc)
        try await db.finishSession(row("s3", book: b1, localDate: "2026-11-11", minutes: 7, words: 900), timeZone: utc)
        try await db.finishSession(row("s4", book: b2, localDate: "2026-11-12", minutes: 40, words: 9000), timeZone: utc)
        try await db.softDeleteSession(id: "s4", timeZone: utc)  // the day's only session
        try await db.softDeleteSession(id: "s2", timeZone: utc)

        // Crash recovery path.
        var tracker = SessionTracker(config: TrackerConfig(timeZone: utc))
        let t0 = date("2026-11-13T12:00:00.000Z")
        let context = SessionContext(bookID: b2, deviceID: "device-1", readingMode: "paginated",
                                     fontSize: 1.0, isFixedLayout: false)
        func page(_ w: Int) -> TrackerEvent {
            .location(LocationSample(kind: .pageTurn, wordIdx: w, chapterID: nil, progression: 0.5,
                                     totalProgression: 0.25, locatorJSON: "{}"))
        }
        var outputs: [TrackerOutput] = []
        for (offset, event) in [(0.0, TrackerEvent.open(context)), (0, page(1000)), (30, page(1250)), (30, .tick),
                                (60, page(1500)), (60, .tick), (90, page(1750)), (90, .tick), (120, .tick)] {
            outputs += tracker.handle(event, at: t0.addingTimeInterval(offset))
        }
        for case .checkpoint(let draft) in outputs { try await db.saveCheckpoint(draft) }
        #expect(try await db.recoverDrafts(timeZone: utc) == 1)
        #expect(try dailyRow(db, "2026-11-13")?["sessions"] as Int? == 1)

        let h1 = try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "a", locatorJSON: "{}"),
                                            now: date("2026-11-11T12:00:00.000Z"), timeZone: utc)
        try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "b", locatorJSON: "{}"),
                                   now: date("2026-11-14T12:00:00.000Z"), timeZone: utc)
        try await db.softDeleteHighlight(id: h1.id, timeZone: utc)

        #expect(try dailyRow(db, "2026-11-12") == nil)  // last session deleted → row removed
        let d10 = try #require(try dailyRow(db, "2026-11-10"))
        #expect(d10["active_minutes"] as Double == 30)  // s2 soft-deleted
        #expect(d10["books_touched"] as Int == 1)
        let d14 = try #require(try dailyRow(db, "2026-11-14"))  // highlight-only day
        #expect(d14["sessions"] as Int == 0)
        #expect(d14["highlights_created"] as Int == 1)
        #expect(d14["goal_met"] as Int == 0)
        #expect(try dailyRow(db, "2026-11-11")?["highlights_created"] as Int? == 0)

        let incremental = try snapshot(db)
        try await db.rebuildAggregates(timeZone: utc)
        #expect(try snapshot(db) == incremental)
    }

    /// Books with no sessions or highlights get the same row from import / indexing as from a rebuild.
    @Test func untouchedAndReindexedBooksMatchRebuild() async throws {
        let db = try AppDatabase.inMemory()
        let fresh = try await addBook(db, "fresh")
        let read = try await addBook(db, "read")
        try await db.finishSession(row("s1", book: read, localDate: "2026-11-10", minutes: 10, words: 100,
                                       endWordIdx: 250), timeZone: utc)
        #expect(try bookRow(db, fresh)?["sessions"] as Int? == 0)
        // Indexing sets word_count, which switches pct_complete to words.
        let chapter = ChapterIndex(spineIndex: 0, href: "c.xhtml", title: "C", isLinear: true, wordCount: 1000,
                                   charCount: 5000, cumWordsStart: 0, textHash: "h", anchors: [])
        try await db.saveIndex(bookID: read, chapters: [chapter], version: 1)
        #expect(try bookRow(db, read)?["pct_complete"] as Double? == 0.25)

        let incremental = try snapshot(db)
        try await db.rebuildAggregates(timeZone: utc)
        #expect(try snapshot(db) == incremental)
    }

    /// The highlight window must match the tracker's reading-day rule on a DST change.
    /// America/New_York, 2026-11-01 (clocks go back at 02:00). Reading day 11-01 starts at local
    /// midnight (EDT, 04:00Z) + 4 h = 08:00Z, the same rule as `ReadingDay.localDate`.
    @Test func dstDayWindowMatchesTrackerRule() async throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let window = try #require(ReadingDays.window(for: "2026-11-01", dayStartHour: 4, timeZone: newYork))
        #expect(window.start == "2026-11-01T08:00:00.000Z")
        let instant = date("2026-11-01T08:30:00.000Z")
        #expect(ReadingDay.localDate(for: instant, timeZone: newYork, dayStartHour: 4) == "2026-11-01")

        let db = try AppDatabase.inMemory()
        let b1 = try await addBook(db, "h1")
        try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "a", locatorJSON: "{}"),
                                   now: instant, timeZone: newYork)
        #expect(try dailyRow(db, "2026-11-01")?["highlights_created"] as Int? == 1)
        let incremental = try snapshot(db)
        try await db.rebuildAggregates(timeZone: newYork)
        #expect(try snapshot(db) == incremental)
    }

    /// highlights_created uses the highlight's reading day: 02:00 local with day start 4 belongs
    /// to the previous day.
    @Test func highlightBucketedByReadingDay() async throws {
        let db = try AppDatabase.inMemory()
        let b1 = try await addBook(db, "h1")
        try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "a", locatorJSON: "{}"),
                                   now: date("2026-11-21T02:00:00.000Z"), timeZone: utc)
        #expect(try dailyRow(db, "2026-11-20")?["highlights_created"] as Int? == 1)
        #expect(try dailyRow(db, "2026-11-21") == nil)
        #expect(try bookRow(db, b1)?["highlights"] as Int? == 1)
    }

    /// pct_complete: max end_word_idx / word_count when indexed (capped at 1), else the stored
    /// Readium total progression. Median session minutes and avg_wpm (ratio of sums).
    @Test func bookStats() async throws {
        let db = try AppDatabase.inMemory()
        let indexed = try await addBook(db, "h1")
        let unindexed = try await addBook(db, "h2")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE dim_book SET word_count = 10000 WHERE book_id = ?", arguments: [indexed])
        }
        try await db.updateResumePoint(bookID: unindexed, locatorJSON: "{}", totalProgression: 0.4)
        try await db.finishSession(row("s1", book: indexed, localDate: "2026-11-10", minutes: 10, words: 3000,
                                       endWordIdx: 3000), timeZone: utc)
        try await db.finishSession(row("s2", book: indexed, localDate: "2026-11-12", minutes: 30, words: 3000,
                                       endWordIdx: 5200), timeZone: utc)
        try await db.finishSession(row("s3", book: indexed, localDate: "2026-11-11", minutes: 20, words: 2000,
                                       eligible: false, endWordIdx: 4000), timeZone: utc)
        try await db.finishSession(row("s4", book: unindexed, localDate: "2026-11-11", minutes: 5, words: 500),
                                   timeZone: utc)

        let b = try #require(try bookRow(db, indexed))
        #expect(b["total_active_minutes"] as Double == 60)
        #expect(b["total_words_read"] as Int == 8000)
        #expect(b["sessions"] as Int == 3)
        #expect(b["first_read_date"] as String == "2026-11-10")
        #expect(b["last_read_date"] as String == "2026-11-12")
        // Eligible only: (3000 + 3000) / (10 + 30) = 150, not avg of ratios (300 + 100) / 2 = 200.
        #expect(b["avg_wpm"] as Double == 150)
        #expect(b["median_session_minutes"] as Double == 20)  // 10, 20, 30
        #expect(b["pct_complete"] as Double == 0.52)          // 5200 / 10000
        #expect(try bookRow(db, unindexed)?["pct_complete"] as Double? == 0.4)

        try await db.softDeleteBook(id: unindexed)
        #expect(try bookRow(db, unindexed) == nil)
    }

    @Test func settingsAccessors() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.dayStartHour() == 4)
        #expect(try await db.streakMinMinutes() == 5)
        try await db.setDayStartHour(3)
        try await db.setStreakMinMinutes(10)
        #expect(try await db.dayStartHour() == 3)
        #expect(try await db.streakMinMinutes() == 10)
        // Same storage the tracker config reads.
        #expect(try await db.trackerConfig(timeZone: utc).dayStartHour == 3)
    }
}
