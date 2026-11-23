import Foundation
import GRDB
import Persistence
import Testing
import Tracking
@testable import Metrics

// Golden tests for the Year in reading, Books and per-book stats queries (stats-tab design).
// Time zone UTC, day start 4, so a session at 12:00Z on D has local_date D. "Today" = 2026-11-22.

private let utc = TimeZone(identifier: "UTC")!
private let today = "2026-11-22"

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

private func approx(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tolerance
}

private func row(_ id: String, book: String, localDate: String, minutes: Double, words: Int,
                 endWordIdx: Int? = nil) -> SessionRow {
    let start = date("\(localDate)T12:00:00.000Z")
    return SessionRow(sessionID: id, bookID: book, deviceID: "device-1", startedAt: start,
                      endedAt: start.addingTimeInterval(minutes * 60), localDate: localDate,
                      localStartHour: 12, tzOffsetMinutes: 0, wallSeconds: minutes * 60,
                      activeSeconds: minutes * 60, startWordIdx: 0, endWordIdx: endWordIdx,
                      wordsRead: words, startTotalProgression: 0, endTotalProgression: 0.1,
                      startLocatorJSON: "{}", endLocatorJSON: "{}", pageTurns: 5, jumpCount: 0,
                      readingMode: "paginated", fontSize: 1, endReason: .closed, isPaceEligible: true)
}

private func addBook(_ db: AppDatabase, _ hash: String, wordCount: Int? = nil,
                     status: String? = nil) async throws -> String {
    let result = try await db.importBook(NewBook(contentHash: hash, title: "Book \(hash)", authors: "Author \(hash)",
                                                 fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1))
    guard case .inserted(let book) = result else { throw CancellationError() }
    try await db.writer.write { db in
        if let wordCount {
            try db.execute(sql: "UPDATE dim_book SET word_count = ? WHERE book_id = ?", arguments: [wordCount, book.id])
        }
        if let status {
            try db.execute(sql: "UPDATE dim_book SET status = ? WHERE book_id = ?", arguments: [status, book.id])
        }
    }
    return book.id
}

private struct Fixture {
    let db: AppDatabase
    let a: String, b: String, c: String, f: String, g: String, e: String
}

/// | book | words  | sessions (day: min / words / end idx)                                        |
/// |------|--------|------------------------------------------------------------------------------|
/// | A    | 10000  | 2025-12-31: 60/100/100; 11-10: 10/1000/1000; 11-20: 20/2000/3000;             |
/// |      |        | 11-21: 30/4000/6900; 11-21 deleted: 50/9999/9999                              |
/// | B    | null   | 01-15: 5/100; 11-05: 15/1500; 11-20: 5/500; 2027-01-01: 7/50 (other year)     |
/// | C    | 5000   | 11-22: 10/100/100, book then soft-deleted                                     |
/// | F    | 8000   | 11-15: 10/500/500, status finished                                            |
/// | G    | 1000   | 11-22: 10/1000/1000 (read to the end)                                         |
/// | E    | 1000   | no sessions                                                                   |
private func makeFixture() async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let a = try await addBook(db, "a", wordCount: 10000)
    let b = try await addBook(db, "b")
    let c = try await addBook(db, "c", wordCount: 5000)
    let f = try await addBook(db, "f", wordCount: 8000, status: "finished")
    let g = try await addBook(db, "g", wordCount: 1000)
    let e = try await addBook(db, "e", wordCount: 1000)
    let rows = [
        row("a-2025", book: a, localDate: "2025-12-31", minutes: 60, words: 100, endWordIdx: 100),
        row("a-10", book: a, localDate: "2026-11-10", minutes: 10, words: 1000, endWordIdx: 1000),
        row("a-20", book: a, localDate: "2026-11-20", minutes: 20, words: 2000, endWordIdx: 3000),
        row("a-21", book: a, localDate: "2026-11-21", minutes: 30, words: 4000, endWordIdx: 6900),
        row("a-del", book: a, localDate: "2026-11-21", minutes: 50, words: 9999, endWordIdx: 9999),
        row("b-jan", book: b, localDate: "2026-01-15", minutes: 5, words: 100),
        row("b-05", book: b, localDate: "2026-11-05", minutes: 15, words: 1500),
        row("b-20", book: b, localDate: "2026-11-20", minutes: 5, words: 500),
        row("b-2027", book: b, localDate: "2027-01-01", minutes: 7, words: 50),
        row("c-22", book: c, localDate: "2026-11-22", minutes: 10, words: 100, endWordIdx: 100),
        row("f-15", book: f, localDate: "2026-11-15", minutes: 10, words: 500, endWordIdx: 500),
        row("g-22", book: g, localDate: "2026-11-22", minutes: 10, words: 1000, endWordIdx: 1000),
    ]
    for r in rows { try await db.finishSession(r, timeZone: utc) }
    try await db.softDeleteSession(id: "a-del", timeZone: utc)
    try await db.softDeleteBook(id: c)
    return Fixture(db: db, a: a, b: b, c: c, f: f, g: g, e: e)
}

private func read<T: Sendable>(_ db: AppDatabase, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
    try await db.reader.read { try body($0) }
}

@Suite struct YearStatsTests {
    @Test func calendarDaysSumPerDayWithinTheYear() async throws {
        let f = try await makeFixture()
        let days = try await read(f.db) { try MetricsQueries.calendarDays($0, year: 2026) }
        // 11-20 is A 20 + B 5; 11-21 excludes the soft-deleted 50 min; 11-22 is C (book deleted, session kept)
        // 10 + G 10. 2025-12-31 and 2027-01-01 fall outside.
        #expect(days.map(\.localDate) == ["2026-01-15", "2026-11-05", "2026-11-10", "2026-11-15", "2026-11-20",
                                          "2026-11-21", "2026-11-22"])
        #expect(days.map(\.minutes) == [5, 15, 10, 10, 25, 30, 20])
    }

    @Test func calendarDaysOtherYearAndBoundaries() async throws {
        let f = try await makeFixture()
        let y2025 = try await read(f.db) { try MetricsQueries.calendarDays($0, year: 2025) }
        #expect(y2025.map(\.localDate) == ["2025-12-31"])
        #expect(y2025.map(\.minutes) == [60])
        let y2027 = try await read(f.db) { try MetricsQueries.calendarDays($0, year: 2027) }
        #expect(y2027.map(\.localDate) == ["2027-01-01"])
        #expect(y2027.map(\.minutes) == [7])
    }

    @Test func minutesByMonthHasTwelveMonths() async throws {
        let f = try await makeFixture()
        let months = try await read(f.db) { try MetricsQueries.minutesByMonth($0, year: 2026) }
        #expect(months.map(\.month) == Array(1...12))
        // Jan: 5. Nov: 15 + 10 + 10 + 25 + 30 + 20 = 110.
        #expect(months.map(\.minutes) == [5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 110, 0])
    }

    @Test func emptyDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let days = try await read(db) { try MetricsQueries.calendarDays($0, year: 2026) }
        #expect(days.isEmpty)
        let months = try await read(db) { try MetricsQueries.minutesByMonth($0, year: 2026) }
        #expect(months.map(\.month) == Array(1...12))
        #expect(months.allSatisfy { $0.minutes == 0 })
    }
}

@Suite struct FirstYearAndInProgressTests {
    @Test func firstReadingYearIgnoresDeletedSessions() async throws {
        let empty = try AppDatabase.inMemory()
        #expect(try await read(empty) { try MetricsQueries.firstReadingYear($0) } == nil)
        let f = try await makeFixture()
        #expect(try await read(f.db) { try MetricsQueries.firstReadingYear($0) } == 2025)
        try await f.db.writer.write { db in
            try db.execute(sql: "UPDATE fact_reading_session SET deleted_at = '2026-11-22T00:00:00.000Z' WHERE session_id = 'a-2025'")
        }
        #expect(try await read(f.db) { try MetricsQueries.firstReadingYear($0) } == 2026)
        try await f.db.writer.write { db in
            try db.execute(sql: "UPDATE fact_reading_session SET deleted_at = '2026-11-22T00:00:00.000Z'")
        }
        #expect(try await read(f.db) { try MetricsQueries.firstReadingYear($0) } == nil)
    }

    @Test func booksInProgressCountsLiveReadingBooksWithoutSessions() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await read(db) { try MetricsQueries.booksInProgressCount($0) } == 0)
        _ = try await addBook(db, "r1", status: "reading")          // no sessions
        _ = try await addBook(db, "r2", status: "reading")
        _ = try await addBook(db, "t", status: "to_read")
        _ = try await addBook(db, "f", status: "finished")
        _ = try await addBook(db, "x", status: "abandoned")
        let gone = try await addBook(db, "g", status: "reading")
        try await db.softDeleteBook(id: gone)
        #expect(try await read(db) { try MetricsQueries.booksInProgressCount($0) } == 2)
    }
}

@Suite struct BookSummariesTests {
    @Test func orderedByLastReadExcludingDeletedAndUnreadBooks() async throws {
        let f = try await makeFixture()
        let books = try await read(f.db) { try MetricsQueries.bookSummaries($0) }
        // B 2027-01-01 (its other-year session), G 11-22, A 11-21, F 11-15. C is deleted, E has no sessions.
        #expect(books.map(\.bookID) == [f.b, f.g, f.a, f.f])
        #expect(books.map(\.lastReadDate) == ["2027-01-01", "2026-11-22", "2026-11-21", "2026-11-15"])
    }

    @Test func fieldsComeFromBookStats() async throws {
        let f = try await makeFixture()
        let books = try await read(f.db) { try MetricsQueries.bookSummaries($0) }
        let a = try #require(books.first { $0.bookID == f.a })
        #expect(a.title == "Book a")
        #expect(a.authors == "Author a")
        // 60 + 10 + 20 + 30 = 120 minutes (the deleted 50 is excluded); 7100 words / 120 min.
        #expect(approx(a.activeMinutes, 120))
        #expect(approx(a.wpm, 7100.0 / 120.0))
        // Max end word idx 6900 (not the deleted 9999) of 10000.
        #expect(approx(a.pctComplete, 0.69))
        let b = try #require(books.first { $0.bookID == f.b })
        // B: 5 + 15 + 5 + 7 = 32 minutes, 2150 words; not indexed, so pct falls back to stored progression (0).
        #expect(approx(b.activeMinutes, 32))
        #expect(approx(b.wpm, 2150.0 / 32.0))
        #expect(approx(b.pctComplete, 0))
        let g = try #require(books.first { $0.bookID == f.g })
        #expect(approx(g.pctComplete, 1))
        #expect(approx(g.wpm, 100))
        #expect(books.last?.status == "finished")
    }

    @Test func emptyDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let books = try await read(db) { try MetricsQueries.bookSummaries($0) }
        #expect(books.isEmpty)
    }
}

@Suite struct ChapterPaceTests {
    private func seed(_ f: Fixture) async throws {
        try await f.db.writer.write { [a = f.a, b = f.b] db in
            // Inserted out of spine order on purpose.
            try db.execute(sql: """
                INSERT INTO dim_chapter (chapter_id, book_id, spine_index, title, word_count)
                VALUES ('ch2', :a, 2, 'Three', 100), ('ch1', :a, 1, 'Two', 100), ('ch0', :a, 0, 'One', 100),
                       ('bch0', :b, 0, 'Other', 100)
                """, arguments: ["a": a, "b": b])
            try db.execute(sql: """
                INSERT INTO fact_location_event (event_id, session_id, book_id, chapter_id, words_delta,
                                                 seconds_since_prev, is_counted)
                VALUES ('e1', 's', :a, 'ch1', 40, 600, 1),
                       ('e2', 's', :a, 'ch1', 20, 60, 1),
                       ('e3', 's', :a, 'ch0', 10, 30, 1),
                       ('e4', 's', :a, 'ch0', 5, NULL, 1),
                       ('e5', 's', :a, 'ch0', 99, 100, 0),
                       ('e6', 's', :a, NULL, 99, 100, 1),
                       ('e7', 's', :b, 'bch0', 99, 100, 1)
                """, arguments: ["a": a, "b": b])
        }
    }

    @Test func minutesCappedWordsSummedInSpineOrder() async throws {
        let f = try await makeFixture()
        try await seed(f)
        let pace = try await read(f.db) { [a = f.a] in try MetricsQueries.chapterPace($0, bookID: a) }
        // ch2 has no counted events. ch0: 30 s + NULL gap (0) = 0.5 min, 15 words, under a minute so wpm nil.
        // ch1: the 600 s gap is capped to 180, plus 60 = 240 s = 4 min, 60 words, 15 wpm.
        #expect(pace.map(\.chapterID) == ["ch0", "ch1"])
        #expect(pace.map(\.title) == ["One", "Two"])
        #expect(pace.map(\.spineIndex) == [0, 1])
        #expect(pace.map(\.minutes) == [0.5, 4])
        #expect(pace.map(\.wordsRead) == [15, 60])
        #expect(pace[0].wpm == nil)
        #expect(approx(pace[1].wpm, 15))
    }

    @Test func softDeletedSessionEventsExcludedAndSessionlessEventsKept() async throws {
        let f = try await makeFixture()
        try await f.db.writer.write { [a = f.a] db in
            try db.execute(sql: """
                INSERT INTO dim_chapter (chapter_id, book_id, spine_index, title, word_count)
                VALUES ('ch0', :a, 0, 'One', 100)
                """, arguments: ["a": a])
            // a-del is soft-deleted; a-21 is live; 'live-unwritten' has no session row yet.
            try db.execute(sql: """
                INSERT INTO fact_location_event (event_id, session_id, book_id, chapter_id, words_delta,
                                                 seconds_since_prev, is_counted)
                VALUES ('d1', 'a-del', :a, 'ch0', 1000, 60, 1),
                       ('l1', 'a-21', :a, 'ch0', 10, 60, 1),
                       ('u1', 'live-unwritten', :a, 'ch0', 5, 30, 1)
                """, arguments: ["a": a])
        }
        let pace = try await read(f.db) { [a = f.a] in try MetricsQueries.chapterPace($0, bookID: a) }
        #expect(pace.map(\.wordsRead) == [15])
        #expect(pace.map(\.minutes) == [1.5])
    }

    @Test func noEventsAndUnknownBook() async throws {
        let f = try await makeFixture()
        let none = try await read(f.db) { [a = f.a] in try MetricsQueries.chapterPace($0, bookID: a) }
        #expect(none.isEmpty)
        let unknown = try await read(f.db) { try MetricsQueries.chapterPace($0, bookID: "nope") }
        #expect(unknown.isEmpty)
    }
}

@Suite struct ProjectedFinishTests {
    @Test func wordsLeftOverRecentRate() async throws {
        let f = try await makeFixture()
        // Window 11-09…11-22. A read 1000 + 2000 + 4000 = 7000 words (2025 and the deleted session are out):
        // 500 words/day. Left: 10000 − 6900 = 3100 → 6.2 → 7 days → 11-29.
        let finish = try await read(f.db) { [a = f.a] in try MetricsQueries.projectedFinish($0, bookID: a, today: today) }
        #expect(finish == "2026-11-29")
    }

    @Test func windowIsFourteenDaysInclusive() async throws {
        let f = try await makeFixture()
        // Today 11-23: window 11-10…11-23 still holds all 7000 words. Today 11-24: 11-11…11-24 loses the 1000
        // read on 11-10, leaving 6000 → 428.57/day; 3100 left → 7.23 → 8 days → 12-02.
        let d23 = try await read(f.db) { [a = f.a] in try MetricsQueries.projectedFinish($0, bookID: a, today: "2026-11-23") }
        #expect(d23 == "2026-11-30")
        let d24 = try await read(f.db) { [a = f.a] in try MetricsQueries.projectedFinish($0, bookID: a, today: "2026-11-24") }
        #expect(d24 == "2026-12-02")
    }

    @Test func nilCases() async throws {
        let f = try await makeFixture()
        func finish(_ book: String, _ day: String = today) async throws -> String? {
            try await read(f.db) { try MetricsQueries.projectedFinish($0, bookID: book, today: day) }
        }
        let r3561 = try await finish(f.b)
        #expect(r3561 == nil)            // word_count not indexed
        let r52 = try await finish(f.f)
        #expect(r52 == nil)            // finished, even with reading in the window
        let r7552 = try await finish(f.g)
        #expect(r7552 == nil)            // read to the end: nothing left
        let r3120 = try await finish(f.c)
        #expect(r3120 == nil)            // deleted book
        let r5478 = try await finish(f.e)
        #expect(r5478 == nil)            // no reading
        let r5375 = try await finish(f.a, "2027-06-01")
        #expect(r5375 == nil)  // no reading in the window
        let r1902 = try await finish("nope")
        #expect(r1902 == nil)
    }
}

@Suite struct HighlightDensityTests {
    @Test func perTenThousandWordsRead() async throws {
        let f = try await makeFixture()
        for q in ["a", "b", "c"] {
            _ = try await f.db.saveHighlight(NewHighlight(bookID: f.a, quoteExact: q, locatorJSON: "{}"),
                                             now: date("2026-11-20T12:00:00.000Z"), timeZone: utc)
        }
        let gone = try await f.db.saveHighlight(NewHighlight(bookID: f.a, quoteExact: "d", locatorJSON: "{}"),
                                                now: date("2026-11-20T12:05:00.000Z"), timeZone: utc)
        try await f.db.softDeleteHighlight(id: gone.id, timeZone: utc)
        // 3 live highlights over 7100 words read.
        let density = try await read(f.db) { [a = f.a] in try MetricsQueries.highlightDensity($0, bookID: a) }
        #expect(approx(density, 3 * 10000.0 / 7100.0))
    }

    @Test func zeroHighlightsIsZeroAndNoWordsIsNil() async throws {
        let f = try await makeFixture()
        func density(_ book: String) async throws -> Double? {
            try await read(f.db) { try MetricsQueries.highlightDensity($0, bookID: book) }
        }
        let r8645 = try await density(f.b)
        #expect(r8645 == 0)
        let r6343 = try await density(f.e)
        #expect(r6343 == nil)       // no sessions, so no words read
        let r7838 = try await density(f.c)
        #expect(r7838 == nil)       // deleted book
        let r1736 = try await density("nope")
        #expect(r1736 == nil)
    }
}
