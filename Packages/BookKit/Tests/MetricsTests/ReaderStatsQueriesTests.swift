import Foundation
import GRDB
import Persistence
import Testing
import Tracking
@testable import Metrics

// Reader-stats baseline and settings queries. Time zone UTC, day start 4: a session at 12:00Z on D
// has local_date D. "Now" is 2026-11-22T15:00Z, so today = 2026-11-22.

private let utc = TimeZone(identifier: "UTC")!
private let now = Timestamp.date(from: "2026-11-22T15:00:00.000Z")!
private let today = "2026-11-22"

private func row(_ id: String, book: String, localDate: String, minutes: Double, words: Int,
                 eligible: Bool = true, hour: Int = 12) -> SessionRow {
    let start = Timestamp.date(from: "\(localDate)T\(String(format: "%02d", hour)):00:00.000Z")!
    return SessionRow(sessionID: id, bookID: book, deviceID: "device-1", startedAt: start,
                      endedAt: start.addingTimeInterval(minutes * 60), localDate: localDate,
                      localStartHour: hour, tzOffsetMinutes: 0, wallSeconds: minutes * 60,
                      activeSeconds: minutes * 60, startWordIdx: 0, endWordIdx: nil,
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

struct ReaderStatsQueriesTests {
    @Test func todaySumsFinishedSessionsOnlyForThatDay() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await addBook(db, "a")
        let b = try await addBook(db, "b")
        try await db.finishSession(row("t1", book: a, localDate: today, minutes: 10, words: 1000), timeZone: utc)
        // Different book and not pace-eligible: still counts toward today.
        try await db.finishSession(row("t2", book: b, localDate: today, minutes: 5, words: 500,
                                       eligible: false, hour: 18), timeZone: utc)
        try await db.finishSession(row("y1", book: a, localDate: "2026-11-21", minutes: 20, words: 2000), timeZone: utc)
        try await db.finishSession(row("t-deleted", book: a, localDate: today, minutes: 50, words: 100,
                                       hour: 20), timeZone: utc)
        try await db.softDeleteSession(id: "t-deleted", timeZone: utc)

        let seconds = try await db.writer.read { db in
            try MetricsQueries.todayFinishedActiveSeconds(db, today: today)
        }
        #expect(seconds == 900)
    }

    @Test func todayIsZeroWithNoSessions() async throws {
        let db = try AppDatabase.inMemory()
        let seconds = try await db.writer.read { db in
            try MetricsQueries.todayFinishedActiveSeconds(db, today: today)
        }
        #expect(seconds == 0)
    }

    @Test func baselineCarriesGoalAndPace() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "a")
        try await db.setGoal(.dailyMinutes, target: 25, effectiveFrom: "2026-11-01",
                             now: Timestamp.date(from: "2026-11-01T12:00:00.000Z")!, timeZone: utc)
        // 20 eligible minutes, 5200 words: book pace (>= 15 min) = 5200 * 60 / 1200 = 260 wpm.
        try await db.finishSession(row("s1", book: book, localDate: "2026-11-20", minutes: 12, words: 3000), timeZone: utc)
        try await db.finishSession(row("s2", book: book, localDate: today, minutes: 8, words: 2200), timeZone: utc)

        let (baseline, pace) = try await db.writer.read { db in
            (try MetricsQueries.readerStatsBaseline(db, bookID: book, now: now, timeZone: utc),
             try MetricsQueries.bookPace(db, bookID: book, today: today))
        }
        #expect(baseline.today == today)
        #expect(baseline.goalMinutes == 25)
        #expect(baseline.todayFinishedSeconds == 480)
        #expect(baseline.usualWPM != nil)
        #expect(baseline.usualWPM == pace)
        #expect(abs((baseline.usualWPM ?? 0) - 260) < 1e-9)
    }

    @Test func baselineWithoutGoalOrPace() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "a")
        // The v6 migration seeds a 30-minute default goal; remove it to test "no goal".
        try await db.writer.write { db in try db.execute(sql: "DELETE FROM dim_goal") }
        let baseline = try await db.writer.read { db in
            try MetricsQueries.readerStatsBaseline(db, bookID: book, now: now, timeZone: utc)
        }
        #expect(baseline == ReaderStatsBaseline(today: today, usualWPM: nil, todayFinishedSeconds: 0, goalMinutes: nil))
    }

    @Test func settingsDefaultWhenUnset() async throws {
        let db = try AppDatabase.inMemory()
        let settings = try await db.writer.read { db in try MetricsQueries.readerStatsSettings(db) }
        #expect(settings == .default)
    }

    /// Hand-built JSON per the codec rules, so this does not depend on the encoder. It needs the
    /// real `ReaderStatsSettings.decode`, so it fails against the Task 2 stub until that merges.
    @Test func settingsReadBackAfterWrite() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setSettingJSON(#"["chapter_time_left","session_wpm"]"#, forKey: ReaderStatsSettings.panelKey)
        try await db.setSettingJSON(#"{"enabled":false,"stats":["session_time"]}"#, forKey: ReaderStatsSettings.lineKey)

        let settings = try await db.writer.read { db in try MetricsQueries.readerStatsSettings(db) }
        #expect(settings == ReaderStatsSettings(panel: [.chapterTimeLeft, .sessionWPM],
                                                lineEnabled: false, line: [.sessionTime]))
    }
}
