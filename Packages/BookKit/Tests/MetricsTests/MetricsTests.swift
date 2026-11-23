import Foundation
import GRDB
import Persistence
import Testing
import Tracking
@testable import Metrics

// Golden tests (PLAN M5 acceptance): a seeded fixture DB with hand-computed expected values.
// Time zone UTC, day start 4, so a session at 12:00Z on D has local_date D. "Today" = 2026-11-22
// (a Sunday).

private let utc = TimeZone(identifier: "UTC")!

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

private func approx(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tolerance
}

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

private func addBook(_ db: AppDatabase, _ hash: String, wordCount: Int? = nil) async throws -> String {
    let result = try await db.importBook(NewBook(contentHash: hash, title: hash, authors: "A",
                                                 fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1))
    guard case .inserted(let book) = result else { throw CancellationError() }
    if let wordCount {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE dim_book SET word_count = ? WHERE book_id = ?",
                           arguments: [wordCount, book.id])
        }
    }
    return book.id
}

private struct Fixture {
    let db: AppDatabase
    let b1: String, b2: String, b3: String, b4: String
}

/// The golden fixture, written through the app's write paths (so aggregates come from the
/// incremental refresh).
///
/// | day      | book | min | words | eligible | note                                  |
/// |----------|------|-----|-------|----------|---------------------------------------|
/// | 11-01…08 | b3   | 10  | 1000  | no       | 8-day run (longest streak)            |
/// | 11-10    | b4   | 10  | 2000  | yes      |                                       |
/// | 11-14    | b1   | 35  | 7000  | yes      | goal 30 met                           |
/// | 11-15    | b1   | 3   | 300   | yes      | < 5 min: breaks the streak            |
/// | 11-16    | b1   | 10  | 3000  | yes      |                                       |
/// | 11-17    | b1   | 25  | 5000  | yes      | 25 < 30 (old goal) → not met          |
/// | 11-18    | b2   | 25  | 7500  | yes      | 25 ≥ 20 (new goal) → met              |
/// | 11-19    | b2   | 6   | 600   | yes      | (+ a 50 min session, soft-deleted)    |
/// | 11-20    | b1   | 30  | 9000  | yes      | + b2 10 min / 1000 words, ineligible, |
/// |          |      |     |       |          |   started 21:00                        |
/// | 11-21    | b2   | 20  | 4000  | yes      | 20 ≥ 20 → met                         |
/// | 11-22    | b1   | 2   | 100   | yes      | today, below the streak minimum       |
///
/// Goals: 30 min from 11-01, changed to 20 min from 11-18 (after the sessions were written).
private func makeFixture() async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let b1 = try await addBook(db, "b1", wordCount: 10000)
    let b2 = try await addBook(db, "b2", wordCount: 50000)
    let b3 = try await addBook(db, "b3")
    let b4 = try await addBook(db, "b4", wordCount: 20000)
    try await db.writer.write { db in
        try db.execute(sql: """
            INSERT INTO dim_chapter (chapter_id, book_id, spine_index, href, title, is_linear, word_count,
                                     cum_words_start)
            VALUES (:b || ':0', :b, 0, 'c0.xhtml', 'One', 1, 4000, 0),
                   (:b || ':1', :b, 1, 'c1.xhtml', 'Two', 1, 6000, 4000),
                   (:b || ':2', :b, 2, 'notes.xhtml', 'Notes', 0, 500, 10000)
            """, arguments: ["b": b1])
    }
    try await db.setGoal(.dailyMinutes, target: 30, effectiveFrom: "2026-11-01",
                         now: date("2026-11-01T12:00:00.000Z"), timeZone: utc)

    for day in 1...8 {
        let d = String(format: "2026-11-%02d", day)
        try await db.finishSession(row("early-\(day)", book: b3, localDate: d, minutes: 10, words: 1000,
                                       eligible: false, hour: 8), timeZone: utc)
    }
    let rows = [
        row("s10", book: b4, localDate: "2026-11-10", minutes: 10, words: 2000),
        row("s14", book: b1, localDate: "2026-11-14", minutes: 35, words: 7000, endWordIdx: 2000),
        row("s15", book: b1, localDate: "2026-11-15", minutes: 3, words: 300, endWordIdx: 2300),
        row("s16", book: b1, localDate: "2026-11-16", minutes: 10, words: 3000, endWordIdx: 3000),
        row("s17", book: b1, localDate: "2026-11-17", minutes: 25, words: 5000, endWordIdx: 4000),
        row("s18", book: b2, localDate: "2026-11-18", minutes: 25, words: 7500),
        row("s19", book: b2, localDate: "2026-11-19", minutes: 6, words: 600),
        row("s19-deleted", book: b2, localDate: "2026-11-19", minutes: 50, words: 10000),
        row("s20", book: b1, localDate: "2026-11-20", minutes: 30, words: 9000, endWordIdx: 5000),
        row("s20-b2", book: b2, localDate: "2026-11-20", minutes: 10, words: 1000, eligible: false, hour: 21),
        row("s21", book: b2, localDate: "2026-11-21", minutes: 20, words: 4000),
        row("s22", book: b1, localDate: "2026-11-22", minutes: 2, words: 100, endWordIdx: 5200),
    ]
    for r in rows { try await db.finishSession(r, timeZone: utc) }
    try await db.softDeleteSession(id: "s19-deleted", timeZone: utc)

    try await db.setGoal(.dailyMinutes, target: 20, effectiveFrom: "2026-11-18",
                         now: date("2026-11-18T12:00:00.000Z"), timeZone: utc)

    // Highlights: two at 11-20 12:00Z, one at 11-21 02:00Z (reading day 11-20); one 11-20 deleted.
    let h = try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "a", locatorJSON: "{}"),
                                       now: date("2026-11-20T12:00:00.000Z"), timeZone: utc)
    try await db.saveHighlight(NewHighlight(bookID: b1, quoteExact: "b", locatorJSON: "{}"),
                               now: date("2026-11-20T12:30:00.000Z"), timeZone: utc)
    try await db.saveHighlight(NewHighlight(bookID: b2, quoteExact: "c", locatorJSON: "{}"),
                               now: date("2026-11-21T02:00:00.000Z"), timeZone: utc)
    try await db.softDeleteHighlight(id: h.id, timeZone: utc)

    return Fixture(db: db, b1: b1, b2: b2, b3: b3, b4: b4)
}

@Suite struct DailyMetricsGoldenTests {
    @Test func dailyMinutesGoalsAndHighlights() async throws {
        let f = try await makeFixture()
        let days = try await f.db.reader.read { (db: Database) throws in
            try MetricsQueries.daily(db, from: "2026-11-14", to: "2026-11-22")
        }
        #expect(days.map(\.localDate) == ["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17", "2026-11-18",
                                          "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"])
        // Active minutes per day; 11-19 is 6, not 56: the 50-minute session is soft-deleted.
        #expect(days.map(\.activeMinutes) == [35, 3, 10, 25, 25, 6, 40, 20, 2])
        // SCD2: through 11-17 the goal is 30, from 11-18 it is 20.
        #expect(days.map(\.goalMinutes) == [30, 30, 30, 30, 20, 20, 20, 20, 20])
        // 35≥30 ✓, 3, 10, 25<30 ✗ (would pass under 20), 25≥20 ✓, 6, 40≥20 ✓, 20≥20 ✓, 2.
        #expect(days.map(\.goalMet) == [true, false, false, false, true, false, true, true, false])

        let d20 = days[6]
        #expect(d20.sessions == 2)
        #expect(d20.booksTouched == 2)
        #expect(d20.wordsRead == 10000)
        #expect(d20.paceWPM == 300)          // eligible only: 9000 words / 30 min
        #expect(d20.highlightsCreated == 2)  // 3 created on reading day 11-20, 1 deleted
        #expect(days[5].sessions == 1)
        #expect(days[5].wordsRead == 600)
    }

    @Test func incrementalAggregatesEqualFullRebuild() async throws {
        let f = try await makeFixture()
        func snapshot() throws -> [[Row]] {
            try f.db.reader.read { (db: Database) throws in
                [try Row.fetchAll(db, sql: "SELECT * FROM agg_daily_reading ORDER BY local_date"),
                 try Row.fetchAll(db, sql: "SELECT * FROM agg_book_stats ORDER BY book_id")]
            }
        }
        let incremental = try snapshot()
        try await f.db.rebuildAggregates(timeZone: utc)
        #expect(try snapshot() == incremental)
    }

    @Test func goalHitRate() async throws {
        let f = try await makeFixture()
        try await f.db.reader.read { (db: Database) throws in
            // Goal started 11-01. Today (2 min) isn't met → judged through yesterday:
            // 11-01…11-21 = 21 days, met on 11-14, 11-18, 11-20, 11-21 → 4/21.
            #expect(approx(try MetricsQueries.goalHitRate(db, today: "2026-11-22"), 4.0 / 21.0))
            // Today 11-20 is met → included: 11-01…11-20 = 20 days, 3 met → 3/20.
            #expect(approx(try MetricsQueries.goalHitRate(db, today: "2026-11-20"), 3.0 / 20.0))
        }
        // Fresh DB: the goal starts today, today isn't met → no full day yet → nil.
        let empty = try AppDatabase.inMemory()
        let start = try #require(try await empty.currentGoal(.dailyMinutes)?.validFrom)
        try await empty.reader.read { (db: Database) throws in
            #expect(try MetricsQueries.goalHitRate(db, today: start) == nil)
        }
    }
}

@Suite struct StreakGoldenTests {
    // Qualifying days (≥ 5 min): 11-01…11-08 (8), 11-10 (1), 11-14 (1), 11-16…11-21 (6).
    // 11-15 (3 min) and 11-22 (2 min) don't qualify.

    @Test func currentStreakAliveThroughYesterday() async throws {
        let f = try await makeFixture()
        let s = try await f.db.reader.read { db in try MetricsQueries.streaks(db, today: "2026-11-22", minMinutes: 5) }
        #expect(s == StreakSummary(current: 6, longest: 8, currentIncludesToday: false))
    }

    @Test func currentStreakBrokenWhenYesterdayAlsoMissing() async throws {
        let f = try await makeFixture()
        // Today 11-23 has nothing, yesterday 11-22 has 2 min < 5 → 0.
        let s = try await f.db.reader.read { db in try MetricsQueries.streaks(db, today: "2026-11-23", minMinutes: 5) }
        #expect(s == StreakSummary(current: 0, longest: 8, currentIncludesToday: false))
    }

    @Test func currentStreakIncludesQualifyingToday() async throws {
        let f = try await makeFixture()
        // Days after "today" are ignored: 11-16…11-21 with today = 11-21.
        let s = try await f.db.reader.read { db in try MetricsQueries.streaks(db, today: "2026-11-21", minMinutes: 5) }
        #expect(s == StreakSummary(current: 6, longest: 8, currentIncludesToday: true))
    }

    @Test func minMinutesIsBound() async throws {
        let f = try await makeFixture()
        // With a 2-minute minimum, 11-15 and 11-22 qualify: 11-14…11-22 = 9 days, longest too.
        let s = try await f.db.reader.read { db in try MetricsQueries.streaks(db, today: "2026-11-22", minMinutes: 2) }
        #expect(s == StreakSummary(current: 9, longest: 9, currentIncludesToday: true))
    }

    @Test func emptyDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let s = try await db.reader.read { db in try MetricsQueries.streaks(db, today: "2026-11-22", minMinutes: 5) }
        #expect(s == StreakSummary(current: 0, longest: 0, currentIncludesToday: false))
    }
}

@Suite struct PaceGoldenTests {
    // Eligible sessions in the 14-day window 11-09…11-22 (minutes / words):
    // 10/2000, 35/7000, 3/300, 10/3000, 25/5000, 25/7500, 6/600, 30/9000, 20/4000, 2/100
    // Σ = 166 min / 38500 words → 38500 / 166 = 231.927… WPM.
    // Average of the session ratios would be (200+200+100+300+200+300+100+300+200+50)/10 = 195.
    static let rolling = 38500.0 / 166.0

    @Test func rollingPaceIsRatioOfSums() async throws {
        let f = try await makeFixture()
        let pace = try await f.db.reader.read { db in try MetricsQueries.rollingPace(db, today: "2026-11-22") }
        #expect(approx(pace, Self.rolling))
        #expect(!approx(pace, 195, 1))
    }

    @Test func rollingPaceFallsBackTo90DaysBelow20Minutes() async throws {
        let f = try await makeFixture()
        try await f.db.reader.read { (db: Database) throws in
            // Today 12-05: the 14-day window (11-22…12-05) has only 2 eligible minutes (< 20), so the
            // 90-day window is used, which holds every eligible session → same 38500 / 166.
            // (The 14-day window alone would give 100 / 2 = 50.)
            #expect(approx(try MetricsQueries.rollingPace(db, today: "2026-12-05"), Self.rolling))
            // Nothing in the last 90 days → nil.
            #expect(try MetricsQueries.rollingPace(db, today: "2027-06-01") == nil)
        }
    }

    @Test func bookPace() async throws {
        let f = try await makeFixture()
        try await f.db.reader.read { (db: Database) throws in
            // b1: 35+3+10+25+30+2 = 105 min, 7000+300+3000+5000+9000+100 = 24400 words.
            #expect(approx(try MetricsQueries.bookPace(db, bookID: f.b1, today: "2026-11-22"), 24400.0 / 105.0))
            // b2: eligible 25+6+20 = 51 min, 7500+600+4000 = 12100 (ineligible and deleted excluded).
            #expect(approx(try MetricsQueries.bookPace(db, bookID: f.b2, today: "2026-11-22"), 12100.0 / 51.0))
            // b4: only 10 eligible minutes (< 15) → rolling pace.
            #expect(approx(try MetricsQueries.bookPace(db, bookID: f.b4, today: "2026-11-22"), Self.rolling))
            // b3: no eligible sessions → rolling pace.
            #expect(approx(try MetricsQueries.bookPace(db, bookID: f.b3, today: "2026-11-22"), Self.rolling))
        }
    }

    @Test func sessionWPMForEligibleSessions() async throws {
        let f = try await makeFixture()
        let points = try await f.db.reader.read { (db: Database) throws in
            try MetricsQueries.sessionWPM(db, from: "2026-11-19", to: "2026-11-20")
        }
        // 11-19: 600 / 6 = 100 (the deleted session is gone); 11-20: 9000 / 30 = 300 (b2 ineligible).
        #expect(points.map(\.localDate) == ["2026-11-19", "2026-11-20"])
        #expect(points.map(\.wpm) == [100, 300])
    }
}

@Suite struct TimeLeftGoldenTests {
    // b1 pace = 24400 / 105 WPM. Chapters: b1:0 words 0–4000, b1:1 4000–10000, b1:2 non-linear.
    static let pace = 24400.0 / 105.0

    @Test func timeLeftInChapterAndBook() async throws {
        let f = try await makeFixture()
        try await f.db.reader.read { (db: Database) throws in
            // At word 3000 in chapter 0: (0 + 4000 − 3000) = 1000 words → 1000 / pace = 4.303 min;
            // book: (10000 − 3000) = 7000 words → 30.123 min.
            let a = try MetricsQueries.timeLeft(db, bookID: f.b1, chapterID: f.b1 + ":0", currentWordIdx: 3000,
                                                today: "2026-11-22")
            #expect(approx(a.chapterMinutes, 1000 / Self.pace))
            #expect(approx(a.bookMinutes, 7000 / Self.pace))
            #expect(approx(a.chapterMinutes, 4.30327868852459, 1e-9))

            // Word 5000 in chapter 1: (4000 + 6000 − 5000) = 5000 words both ways → 21.516 min.
            let b = try MetricsQueries.timeLeft(db, bookID: f.b1, chapterID: f.b1 + ":1", currentWordIdx: 5000,
                                                today: "2026-11-22")
            #expect(approx(b.chapterMinutes, 5000 / Self.pace))
            #expect(approx(b.bookMinutes, 5000 / Self.pace))

            // No chapter, or a non-linear one → chapter nil; past the end clamps to 0.
            let c = try MetricsQueries.timeLeft(db, bookID: f.b1, chapterID: nil, currentWordIdx: 3000,
                                                today: "2026-11-22")
            #expect(c.chapterMinutes == nil)
            #expect(approx(c.bookMinutes, 7000 / Self.pace))
            let d = try MetricsQueries.timeLeft(db, bookID: f.b1, chapterID: f.b1 + ":2", currentWordIdx: 10100,
                                                today: "2026-11-22")
            #expect(d.chapterMinutes == nil)
            #expect(d.bookMinutes == 0)

            // Unindexed book → both nil.
            let e = try MetricsQueries.timeLeft(db, bookID: f.b3, chapterID: nil, currentWordIdx: 0,
                                                today: "2026-11-22")
            #expect(e == TimeLeft(chapterMinutes: nil, bookMinutes: nil))
        }
    }

    @Test func noPaceMeansNoEstimate() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "x", wordCount: 1000)
        try await db.reader.read { (db: Database) throws in
            let t = try MetricsQueries.timeLeft(db, bookID: book, chapterID: nil, currentWordIdx: 0, today: "2026-11-22")
            #expect(t == TimeLeft(chapterMinutes: nil, bookMinutes: nil))
        }
    }
}

@Suite struct BooksFinishedGoldenTests {
    @Test func booksFinishedThisYear() async throws {
        let db = try AppDatabase.inMemory()
        let march = try await addBook(db, "march")
        let newYearsEve = try await addBook(db, "nye")
        let lastYear = try await addBook(db, "last-year")
        let reopened = try await addBook(db, "reopened")
        let deleted = try await addBook(db, "deleted")
        try await db.setStatus(bookID: march, status: .finished, now: date("2026-03-01T12:00:00.000Z"))
        // 02:00Z on Jan 1 2027 is still reading day 2026-12-31 (day start 4, UTC) → counts for 2026.
        try await db.setStatus(bookID: newYearsEve, status: .finished, now: date("2027-01-01T02:00:00.000Z"))
        try await db.setStatus(bookID: lastYear, status: .finished, now: date("2025-06-01T12:00:00.000Z"))
        try await db.setStatus(bookID: reopened, status: .finished, now: date("2026-05-01T12:00:00.000Z"))
        try await db.setStatus(bookID: reopened, status: .reading, now: date("2026-05-02T12:00:00.000Z"))
        try await db.setStatus(bookID: deleted, status: .finished, now: date("2026-05-01T12:00:00.000Z"))
        try await db.softDeleteBook(id: deleted)

        try await db.reader.read { (db: Database) throws in
            #expect(try MetricsQueries.booksFinished(db, year: 2026, timeZone: utc) == 2)
            #expect(try MetricsQueries.booksFinished(db, year: 2025, timeZone: utc) == 1)
            #expect(try MetricsQueries.booksFinished(db, year: 2027, timeZone: utc) == 0)
            let byMonth = try MetricsQueries.booksFinishedByMonth(db, year: 2026, timeZone: utc)
            #expect(byMonth.map(\.month) == Array(1...12))
            #expect(byMonth.map(\.count) == [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        }
        // Marking another book finished increments this year's count.
        let another = try await addBook(db, "another")
        try await db.setStatus(bookID: another, status: .finished, now: date("2026-11-22T12:00:00.000Z"))
        try await db.reader.read { (db: Database) throws in
            #expect(try MetricsQueries.booksFinished(db, year: 2026, timeZone: utc) == 3)
        }
    }
}

@Suite struct DashboardHelperTests {
    @Test func hourWeekdayProfile() async throws {
        let f = try await makeFixture()
        let profile = try await f.db.reader.read { (db: Database) throws in
            try MetricsQueries.hourWeekdayProfile(db, from: "2026-11-14", to: "2026-11-22")
        }
        // Weekday is Calendar-style (1 = Sunday) of the reading day. 11-14 Sat … 11-22 Sun.
        // Sun 12h: 11-15 (3) + 11-22 (2); Mon 10; Tue 25; Wed 25; Thu 6 (deleted 50 excluded);
        // Fri 12h 30 and 21h 10; Sat 12h: 11-14 (35) + 11-21 (20).
        #expect(profile.map { [$0.weekday, $0.hour] } == [[1, 12], [2, 12], [3, 12], [4, 12], [5, 12],
                                                          [6, 12], [6, 21], [7, 12]])
        #expect(profile.map(\.minutes) == [5, 10, 25, 25, 6, 30, 10, 55])
    }

    @Test func bookStatsAndToday() async throws {
        let f = try await makeFixture()
        try await f.db.reader.read { (db: Database) throws in
            let stats = try #require(try MetricsQueries.bookStats(db, bookID: f.b1))
            #expect(stats.sessions == 6)
            #expect(stats.highlights == 1)
            #expect(stats.pctComplete == 0.52)  // max end_word_idx 5200 / 10000
            #expect(approx(stats.avgWPM, 24400.0 / 105.0))
            // UTC 03:00 is before the 04:00 day start → still the previous reading day.
            #expect(try MetricsQueries.today(db, now: date("2026-11-23T03:00:00.000Z"), timeZone: utc)
                    == "2026-11-22")
        }
    }
}

@Suite struct MetricsPerformanceTests {
    /// ~1,500 synthetic sessions over 2 years on a file-backed pool: daily + streaks + rollingPace +
    /// hourWeekdayProfile together in under 100 ms.
    @Test func dashboardQueriesAreFast() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("metrics-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appendingPathComponent("perf.sqlite"))
        let book = try await addBook(db, "perf", wordCount: 100_000)
        let firstDay = "2024-11-23"
        try await db.writer.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO fact_reading_session (session_id, book_id, local_date, local_start_hour, started_at,
                                                  wall_seconds, active_seconds, words_read, is_pace_eligible)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                """)
            for i in 0..<1500 {
                let day = ReadingDays.adding(i * 730 / 1500, to: firstDay)!
                let active = Double(300 + (i * 37) % 2700)
                try insert.execute(arguments: ["p\(i)", book, day, (i * 7) % 24, "\(day)T12:00:00.000Z",
                                               active, active, Int(active / 60 * 250)])
            }
        }
        try await db.rebuildAggregates(timeZone: utc)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await db.reader.read { (db: Database) throws in
                let days = try MetricsQueries.daily(db, from: "2024-11-23", to: "2026-11-22")
                let streaks = try MetricsQueries.streaks(db, today: "2026-11-22", minMinutes: 5)
                let pace = try MetricsQueries.rollingPace(db, today: "2026-11-22")
                let profile = try MetricsQueries.hourWeekdayProfile(db, from: "2024-11-23", to: "2026-11-22")
                #expect(days.count > 700)
                #expect(streaks.longest > 0)
                #expect(pace != nil)
                #expect(!profile.isEmpty)
            }
        }
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
    }
}

// MARK: - M6 widget snapshot

@Suite struct WidgetSnapshotGoldenTests {
    @Test func snapshotOnFixtureDay() async throws {
        let f = try await makeFixture()
        let now = date("2026-11-22T20:00:00.000Z")
        let snapshot = try await f.db.reader.read { db in
            try MetricsQueries.widgetSnapshot(db, now: now, timeZone: utc)
        }
        #expect(snapshot.today == "2026-11-22")
        #expect(snapshot.dayStartHour == 4)
        #expect(TimeZone(identifier: snapshot.timeZoneID)?.secondsFromGMT() == 0)  // "UTC" reports as "GMT"
        #expect(approx(snapshot.todayMinutes, 2))          // s22
        #expect(snapshot.goalMinutes == 20)                // changed from 30 on 11-18
        #expect(snapshot.streakMinMinutes == 5)
        #expect(snapshot.currentStreak == 6)               // 11-16…11-21; today (2 min) not yet
        #expect(snapshot.streakIncludesToday == false)

        // No book was opened in the app, so the latest session's book wins: s22 → b1.
        let book = try #require(snapshot.continueReading)
        #expect(book.bookID == f.b1)
        #expect(book.title == "b1")
        #expect(approx(book.percentComplete, 0.52))        // end_word_idx 5200 / 10,000
        let expected = try await f.db.reader.read { db in
            try MetricsQueries.timeLeft(db, bookID: f.b1, chapterID: nil, currentWordIdx: 5200, today: "2026-11-22")
        }
        #expect(book.bookMinutesLeft == expected.bookMinutes)
        #expect(book.bookMinutesLeft != nil)
    }

    @Test func lastOpenedBookBeatsLatestSessionAndFinishedBooksAreSkipped() async throws {
        let f = try await makeFixture()
        try await f.db.markOpened(bookID: f.b2, now: date("2026-11-22T19:00:00.000Z"))
        func current() async throws -> String? {
            try await f.db.reader.read { db in
                try MetricsQueries.widgetSnapshot(db, now: date("2026-11-22T20:00:00.000Z"), timeZone: utc)
            }.continueReading?.bookID
        }
        #expect(try await current() == f.b2)
        try await f.db.setStatus(bookID: f.b2, status: .finished)
        #expect(try await current() == f.b1)
    }

    @Test func emptyLibraryHasNoContinueReading() async throws {
        let db = try AppDatabase.inMemory()
        let snapshot = try await db.reader.read { db in
            try MetricsQueries.widgetSnapshot(db, now: date("2026-11-22T20:00:00.000Z"), timeZone: utc)
        }
        #expect(snapshot.continueReading == nil)
        #expect(snapshot.currentStreak == 0)
        #expect(snapshot.todayMinutes == 0)
    }
}
