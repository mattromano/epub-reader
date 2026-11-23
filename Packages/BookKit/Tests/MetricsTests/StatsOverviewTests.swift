import Foundation
import GRDB
import Persistence
import Testing
import Tracking
@testable import Metrics

// Golden tests for the Stats tab overview and Speed queries (stats-tab design). Time zone UTC, so a
// session at hour H on D has local_date D. "Today" = 2026-11-22.

private let utc = TimeZone(identifier: "UTC")!

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

private func approx(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    guard let a else { return false }
    return abs(a - b) < tolerance
}

private func row(_ id: String, book: String, localDate: String, minutes: Double, words: Int,
                 eligible: Bool = true, hour: Int = 12, pages: Int = 5, font: Double? = 1,
                 mode: String = "paginated") -> SessionRow {
    let start = date("\(localDate)T\(String(format: "%02d", hour)):00:00.000Z")
    return SessionRow(sessionID: id, bookID: book, deviceID: "device-1", startedAt: start,
                      endedAt: start.addingTimeInterval(minutes * 60), localDate: localDate,
                      localStartHour: hour, tzOffsetMinutes: 0, wallSeconds: minutes * 60,
                      activeSeconds: minutes * 60, startWordIdx: 0, endWordIdx: nil,
                      wordsRead: words, startTotalProgression: 0, endTotalProgression: 0.1,
                      startLocatorJSON: "{}", endLocatorJSON: "{}", pageTurns: pages, jumpCount: 0,
                      readingMode: mode, fontSize: font, endReason: .closed, isPaceEligible: eligible)
}

private func addBook(_ db: AppDatabase, _ hash: String) async throws -> String {
    let result = try await db.importBook(NewBook(contentHash: hash, title: hash, authors: "A",
                                                 fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1))
    guard case .inserted(let book) = result else { throw CancellationError() }
    return book.id
}

private struct Fixture {
    let db: AppDatabase
    let a: String, b: String, c: String, d: String
}

/// The fixture. Books: A, B, C and D (D soft-deleted). Titles equal the names.
///
/// | id     | book | day   | min | words | elig | hour | font  | pages | note                          |
/// |--------|------|-------|-----|-------|------|------|-------|-------|-------------------------------|
/// | a1     | A    | 11-22 | 30  | 7500  | yes  | 8    | 1.0   | 5     |                               |
/// | a2     | A    | 11-20 | 35  | 7000  | yes  | 20   | 1.25  | 10    |                               |
/// | b1     | B    | 11-09 | 20  | 3000  | yes  | 13   | 1.0   | 4     | first day of the 14-day window|
/// | b2     | B    | 11-08 | 10  | 2000  | yes  | 23   | 1.254 | 0     | day before it; font rounds 1.25|
/// | b3     | B    | 08-25 | 60  | 3000  | yes  | 3    | 0.9   | 6     | first day of the 90-day window|
/// | b3x    | B    | 08-24 | 60  | 90000 | yes  | 3    | 1.0   | 5     | day before it                 |
/// | x      | A    | 11-21 | 40  | 9999  | no   | 9    | 1.0   | 8     | ineligible                    |
/// | del    | A    | 11-22 | 100 | 99999 | yes  | 12   | 1.0   | 5     | soft-deleted session          |
/// | dbk    | D    | 11-21 | 50  | 5000  | yes  | 12   | 1.0   | 5     | book soft-deleted             |
/// | nul    | NULL | 11-21 | 20  | 2000  | yes  | NULL | NULL  | 3     | no book, hour or font size    |
/// | scroll | A    | 11-19 | 10  | 1000  | yes  | 2    | 1.0   | 7     | reading_mode scroll           |
/// | c1     | C    | 11-12 | 9   | 900   | yes  | 6    | 1.1   | 3     | under the 10 minute minimum   |
/// | n1     | B    | 11-11 | 30  | 3000  | yes  | NULL | NULL  | 6     | hour and font size NULL       |
/// | short  | A    | 11-13 | 1   | 0     | no   | 12   | 1.0   | 3     | under 2 minutes               |
/// | two    | A    | 11-14 | 2   | 0     | no   | 12   | 1.0   | 1     | exactly 2 minutes             |
///
/// Books A and B are finished; D is finished too but deleted.
private func makeFixture() async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let a = try await addBook(db, "A")
    let b = try await addBook(db, "B")
    let c = try await addBook(db, "C")
    let d = try await addBook(db, "D")
    let rows = [
        row("a1", book: a, localDate: "2026-11-22", minutes: 30, words: 7500, hour: 8),
        row("a2", book: a, localDate: "2026-11-20", minutes: 35, words: 7000, hour: 20, pages: 10, font: 1.25),
        row("b1", book: b, localDate: "2026-11-09", minutes: 20, words: 3000, hour: 13, pages: 4),
        row("b2", book: b, localDate: "2026-11-08", minutes: 10, words: 2000, hour: 23, pages: 0, font: 1.254),
        row("b3", book: b, localDate: "2026-08-25", minutes: 60, words: 3000, hour: 3, pages: 6, font: 0.9),
        row("b3x", book: b, localDate: "2026-08-24", minutes: 60, words: 90000, hour: 3),
        row("x", book: a, localDate: "2026-11-21", minutes: 40, words: 9999, eligible: false, hour: 9, pages: 8),
        row("del", book: a, localDate: "2026-11-22", minutes: 100, words: 99999),
        row("dbk", book: d, localDate: "2026-11-21", minutes: 50, words: 5000),
        row("nul", book: a, localDate: "2026-11-21", minutes: 20, words: 2000, hour: 15, pages: 3),
        row("scroll", book: a, localDate: "2026-11-19", minutes: 10, words: 1000, hour: 2, pages: 7, mode: "scroll"),
        row("c1", book: c, localDate: "2026-11-12", minutes: 9, words: 900, hour: 6, pages: 3, font: 1.1),
        row("n1", book: b, localDate: "2026-11-11", minutes: 30, words: 3000, hour: 14, pages: 6),
        row("short", book: a, localDate: "2026-11-13", minutes: 1, words: 0, eligible: false, pages: 3),
        row("two", book: a, localDate: "2026-11-14", minutes: 2, words: 0, eligible: false, pages: 1),
    ]
    for r in rows { try await db.finishSession(r, timeZone: utc) }
    try await db.softDeleteSession(id: "del", timeZone: utc)
    try await db.writer.write { db in
        // NULL columns the app's SessionRow can't express (book, hour) or that are optional (font).
        try db.execute(sql: "UPDATE fact_reading_session SET book_id = NULL, local_start_hour = NULL, font_size = NULL WHERE session_id = 'nul'")
        try db.execute(sql: "UPDATE fact_reading_session SET local_start_hour = NULL, font_size = NULL WHERE session_id = 'n1'")
    }
    try await db.setStatus(bookID: a, status: .finished)
    try await db.setStatus(bookID: b, status: .finished)
    try await db.setStatus(bookID: d, status: .finished)
    try await db.softDeleteBook(id: d)
    return Fixture(db: db, a: a, b: b, c: c, d: d)
}

private let allFrom = "2026-08-25"
private let allTo = "2026-11-22"

@Suite struct StatsOverviewTests {
    @Test func lifetimeTotals() async throws {
        let f = try await makeFixture()
        let t = try await f.db.reader.read { try MetricsQueries.lifetimeTotals($0) }
        // Minutes, non-deleted sessions: 30+35+20+10+60+60+40+50+20+10+9+30+1+2 = 377 (the 100 min
        // deleted session is out). Words: 7500+7000+3000+2000+3000+90000+9999+5000+2000+1000+900+3000 = 134399.
        #expect(t.activeSeconds == 377 * 60)
        #expect(t.wordsRead == 134_399)
        #expect(t.sessions == 14)
        // A and B are finished; D is finished but deleted.
        #expect(t.booksFinished == 2)
        #expect(approx(t.novelEquivalent, 134_399.0 / 90_000))
    }

    @Test func paceComparisonUsesRatioOfSumsOverEligibleSessions() async throws {
        let f = try await makeFixture()
        let p = try await f.db.reader.read { try MetricsQueries.paceComparison($0, today: "2026-11-22") }
        // [11-09, 11-22], eligible with a book: a1, a2, b1, dbk, scroll, c1, n1 (b2 is 11-08, x
        // ineligible, nul has no book, del deleted): words 7500+7000+3000+5000+1000+900+3000 = 27400,
        // minutes 30+35+20+50+10+9+30 = 184.
        #expect(approx(p.pace14, 27400.0 / 184))
        // [08-25, 11-22] adds b2 (2000 words, 10 min) and b3 (3000, 60); b3x is 08-24, out.
        #expect(approx(p.pace90, 32400.0 / 254))
        #expect(approx(p.deltaPercent, (27400.0 / 184 / (32400.0 / 254) - 1) * 100))
    }

    @Test func paceComparisonWithOnlyNinetyDayData() async throws {
        let f = try await makeFixture()
        // Window starts: 14 d = 02-02, 90 d = 11-18. Eligible with a book: a1, a2, dbk, scroll.
        let p = try await f.db.reader.read { try MetricsQueries.paceComparison($0, today: "2027-02-15") }
        #expect(p.pace14 == nil)
        #expect(approx(p.pace90, 20500.0 / 125))
        #expect(p.deltaPercent == nil)
    }

    @Test func sessionsThisWeekCountsAndMedian() async throws {
        let f = try await makeFixture()
        // [11-16, 11-22], every non-deleted session: scroll 10, nul 20, a1 30, a2 35, x 40, dbk 50.
        // Even count, so the mean of 30 and 35.
        let week = try await f.db.reader.read { try MetricsQueries.sessionsThisWeek($0, today: "2026-11-22") }
        #expect(week.count == 6)
        #expect(approx(week.medianMinutes, 32.5))
        // [11-15, 11-21]: scroll 10, nul 20, a2 35, x 40, dbk 50; odd count, so the middle value.
        let odd = try await f.db.reader.read { try MetricsQueries.sessionsThisWeek($0, today: "2026-11-21") }
        #expect(odd.count == 5)
        #expect(approx(odd.medianMinutes, 35))
        _ = f
    }

    @Test func wpmByBook() async throws {
        let f = try await makeFixture()
        let groups = try await f.db.reader.read {
            try MetricsQueries.wpmByBook($0, from: allFrom, to: allTo)
        }
        // A: a1 + a2 + scroll = 75 min, 15500 words. B: b1 + b2 + b3 + n1 = 120 min, 11000 words.
        // C has 9 min (under 10), D is deleted, x is ineligible, nul has no book.
        #expect(groups.map(\.key) == [f.a, f.b])
        #expect(groups.map(\.label) == ["A", "B"])
        #expect(approx(groups[0].wpm, 15500.0 / 75))
        #expect(approx(groups[0].minutes, 75))
        #expect(approx(groups[1].wpm, 11000.0 / 120))
        #expect(approx(groups[1].minutes, 120))
        // Exactly 10 minutes is kept (scroll, 11-19).
        let single = try await f.db.reader.read {
            try MetricsQueries.wpmByBook($0, from: "2026-11-19", to: "2026-11-19")
        }
        #expect(single.map(\.key) == [f.a])
        #expect(approx(single[0].wpm, 100))
    }

    @Test func wpmByTimeBand() async throws {
        let f = try await makeFixture()
        let groups = try await f.db.reader.read {
            try MetricsQueries.wpmByTimeBand($0, from: allFrom, to: allTo)
        }
        // Morning (a1 h8, c1 h6): 39 min, 8400 words. Afternoon (b1 h13, dbk h12): 70 min, 8000.
        // Evening (a2 h20): 35 min, 7000. Night (b2 h23, b3 h3, scroll h2): 80 min, 6000.
        // n1 and nul have no hour; x is ineligible.
        #expect(groups.map(\.key) == ["morning", "afternoon", "evening", "night"])
        #expect(groups.map(\.label) == ["Morning", "Afternoon", "Evening", "Night"])
        #expect(approx(groups[0].wpm, 8400.0 / 39))
        #expect(approx(groups[1].wpm, 8000.0 / 70))
        #expect(approx(groups[2].wpm, 200))
        #expect(approx(groups[3].wpm, 75))
        #expect(groups.map(\.minutes) == [39, 70, 35, 80])
        #expect(groups.map(\.id) == groups.map(\.key))

        // [11-20, 11-22]: a1 morning 250, dbk afternoon 100, a2 evening 200; no night session.
        let some = try await f.db.reader.read {
            try MetricsQueries.wpmByTimeBand($0, from: "2026-11-20", to: "2026-11-22")
        }
        #expect(some.map(\.key) == ["morning", "afternoon", "evening"])
        #expect(some.map(\.wpm) == [250, 100, 200])
        // 11-12 holds only c1 (morning, 9 min): under the minimum.
        let thin = try await f.db.reader.read {
            try MetricsQueries.wpmByTimeBand($0, from: "2026-11-12", to: "2026-11-12")
        }
        #expect(thin.isEmpty)
    }

    @Test func timeBandSQLMatchesSwiftBands() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "A")
        // One 10 minute, 1000 word (100 wpm) session per hour, each on its own day.
        for hour in 0..<24 {
            let day = String(format: "2026-11-%02d", hour + 1)
            try await db.finishSession(row("h\(hour)", book: book, localDate: day, minutes: 10, words: 1000,
                                           hour: hour), timeZone: utc)
        }
        for hour in 0..<24 {
            let day = String(format: "2026-11-%02d", hour + 1)
            let groups = try await db.reader.read {
                try MetricsQueries.wpmByTimeBand($0, from: day, to: day)
            }
            #expect(groups.map(\.key) == [TimeBand.band(forHour: hour).rawValue], "hour \(hour)")
        }
    }

    @Test func wpmByFontSize() async throws {
        let f = try await makeFixture()
        let groups = try await f.db.reader.read {
            try MetricsQueries.wpmByFontSize($0, from: allFrom, to: allTo)
        }
        // 0.90: b3 (60 min, 3000). 1.00: a1 + b1 + dbk + scroll (110 min, 16500). 1.25: a2 + b2
        // (1.254 rounds to 1.25; 45 min, 9000). 1.10 is c1 alone (9 min): under the minimum. n1 has a
        // NULL font size, which the app records for the default (1.0), so it joins 1.00: 140 min, 19500
        // words. nul has no font size either but also no book, so it is excluded.
        #expect(groups.map(\.key) == ["0.90", "1.00", "1.25"])
        #expect(groups.map(\.label) == ["90%", "100%", "125%"])
        #expect(groups.map(\.wpm).count == 3)
        #expect(groups[0].wpm == 50 && groups[2].wpm == 200)
        #expect(approx(groups[1].wpm, 19500.0 * 60 / 8400))
        #expect(groups.map(\.minutes) == [60, 140, 45])
    }

    @Test func pagesPerMinuteTrend() async throws {
        let f = try await makeFixture()
        let points = try await f.db.reader.read {
            try MetricsQueries.pagesPerMinuteTrend($0, from: "2026-08-01", to: allTo)
        }
        // Paginated, ≥ 2 min, ≥ 1 page turn, oldest first (same-day ties by start time: x 09:00,
        // dbk 12:00, nul 15:00). Out: b2 (0 pages), short (1 min), scroll (reading mode), del.
        let expected: [(String, Double)] = [
            ("2026-08-24", 5.0 / 60), ("2026-08-25", 6.0 / 60), ("2026-11-09", 4.0 / 20),
            ("2026-11-11", 6.0 / 30), ("2026-11-12", 3.0 / 9), ("2026-11-14", 1.0 / 2),
            ("2026-11-20", 10.0 / 35), ("2026-11-21", 8.0 / 40), ("2026-11-21", 5.0 / 50),
            ("2026-11-21", 3.0 / 20), ("2026-11-22", 5.0 / 30),
        ]
        #expect(points.map(\.localDate) == expected.map(\.0))
        for (point, want) in zip(points, expected) {
            #expect(approx(point.pagesPerMinute, want.1))
        }
        let narrow = try await f.db.reader.read {
            try MetricsQueries.pagesPerMinuteTrend($0, from: "2026-11-13", to: "2026-11-14")
        }
        #expect(narrow.map(\.localDate) == ["2026-11-14"])
    }

    @Test func emptyDatabaseGivesZerosAndEmpty() async throws {
        let db = try AppDatabase.inMemory()
        try await db.reader.read { db in
            let totals = try MetricsQueries.lifetimeTotals(db)
            #expect(totals == LifetimeTotals(activeSeconds: 0, wordsRead: 0, sessions: 0, booksFinished: 0))
            #expect(totals.novelEquivalent == 0)
            let pace = try MetricsQueries.paceComparison(db, today: "2026-11-22")
            #expect(pace == PaceComparison(pace14: nil, pace90: nil))
            #expect(pace.deltaPercent == nil)
            let week = try MetricsQueries.sessionsThisWeek(db, today: "2026-11-22")
            #expect(week.count == 0)
            #expect(week.medianMinutes == nil)
            #expect(try MetricsQueries.wpmByBook(db, from: allFrom, to: allTo).isEmpty)
            #expect(try MetricsQueries.wpmByTimeBand(db, from: allFrom, to: allTo).isEmpty)
            #expect(try MetricsQueries.wpmByFontSize(db, from: allFrom, to: allTo).isEmpty)
            #expect(try MetricsQueries.pagesPerMinuteTrend(db, from: allFrom, to: allTo).isEmpty)
        }
    }
}
