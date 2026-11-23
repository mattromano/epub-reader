import Foundation
import GRDB
import Persistence
import Testing
import Tracking
@testable import Metrics

// Golden tests for the Sessions and Personal bests queries (stats-tab design). Time zone UTC, day
// start 4, so a session at 12:00Z on D has local_date D.

private let utc = TimeZone(identifier: "UTC")!

private func date(_ iso: String) -> Date { Timestamp.date(from: iso)! }

private func row(_ id: String, book: String, localDate: String, seconds: Double, words: Int,
                 eligible: Bool = true, hour: Int = 12, pages: Int = 5) -> SessionRow {
    let start = date("\(localDate)T\(String(format: "%02d", hour)):00:00.000Z")
    return SessionRow(sessionID: id, bookID: book, deviceID: "device-1", startedAt: start,
                      endedAt: start.addingTimeInterval(seconds), localDate: localDate,
                      localStartHour: hour, tzOffsetMinutes: 0, wallSeconds: seconds,
                      activeSeconds: seconds, startWordIdx: 0, endWordIdx: nil,
                      wordsRead: words, startTotalProgression: 0, endTotalProgression: 0.1,
                      startLocatorJSON: "{}", endLocatorJSON: "{}", pageTurns: pages, jumpCount: 0,
                      readingMode: "paginated", fontSize: 1, endReason: .closed, isPaceEligible: eligible)
}

private func addBook(_ db: AppDatabase, _ hash: String) async throws -> String {
    let result = try await db.importBook(NewBook(contentHash: hash, title: hash, authors: "A",
                                                 fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1))
    guard case .inserted(let book) = result else { throw CancellationError() }
    return book.id
}

private struct Fixture {
    let db: AppDatabase
    let alpha: String, beta: String, gamma: String
}

/// | id   | day   | book  | min  | words | elig | pages | note                                   |
/// |------|-------|-------|------|-------|------|-------|----------------------------------------|
/// | s1   | 11-01 | Alpha | 5.0  | 1000  | yes  | 3     | wpm 200                                |
/// | s2   | 11-02 | Alpha | 9    | 2700  | yes  | 4     | wpm 300 but < 10 min                   |
/// | s3   | 11-03 | Beta  | 59.9 | 11980 | yes  | 7     | wpm 200                                |
/// | s4   | 11-04 | Beta  | 61   | 6100  | yes  | 5     | wpm 100                                |
/// | s5   | 11-05 | Alpha | 10   | 2500  | yes  | 7     | wpm 250 (fastest); ties s3 on pages    |
/// | s6   | 11-05 | Beta  | 30   | 3000  | no   | 2     | 20:00; wpm nil                         |
/// | s7   | 11-06 | Alpha | 2    | 100   | yes  | 1     |                                        |
/// | s8   | 11-08 | Gamma | 4    | 400   | yes  | 1     | Gamma is soft-deleted -> title ""      |
/// | s9   | 11-09 | nil   | 3    | 300   | yes  | 1     | book_id NULL                           |
/// | gone | 11-07 | Beta  | 120  | 99999 | yes  | 99    | soft-deleted session: never counted    |
private func makeFixture() async throws -> Fixture {
    let db = try AppDatabase.inMemory()
    let alpha = try await addBook(db, "Alpha")
    let beta = try await addBook(db, "Beta")
    let gamma = try await addBook(db, "Gamma")
    let rows = [
        row("s1", book: alpha, localDate: "2026-11-01", seconds: 300, words: 1000, pages: 3),
        row("s2", book: alpha, localDate: "2026-11-02", seconds: 540, words: 2700, pages: 4),
        row("s3", book: beta, localDate: "2026-11-03", seconds: 3594, words: 11980, pages: 7),
        row("s4", book: beta, localDate: "2026-11-04", seconds: 3660, words: 6100, pages: 5),
        row("s5", book: alpha, localDate: "2026-11-05", seconds: 600, words: 2500, pages: 7),
        row("s6", book: beta, localDate: "2026-11-05", seconds: 1800, words: 3000, eligible: false, hour: 20, pages: 2),
        row("s7", book: alpha, localDate: "2026-11-06", seconds: 120, words: 100, pages: 1),
        row("s8", book: gamma, localDate: "2026-11-08", seconds: 240, words: 400, pages: 1),
        row("s9", book: alpha, localDate: "2026-11-09", seconds: 180, words: 300, pages: 1),
        row("gone", book: beta, localDate: "2026-11-07", seconds: 7200, words: 99999, pages: 99),
    ]
    for r in rows { try await db.finishSession(r, timeZone: utc) }
    try await db.softDeleteSession(id: "gone", timeZone: utc)
    try await db.writer.write { db in
        try db.execute(sql: "UPDATE dim_book SET deleted_at = '2026-11-09T00:00:00.000Z' WHERE book_id = ?",
                       arguments: [gamma])
        try db.execute(sql: "UPDATE fact_reading_session SET book_id = NULL WHERE session_id = 's9'")
    }
    return Fixture(db: db, alpha: alpha, beta: beta, gamma: gamma)
}

@Suite struct SessionLogTests {
    @Test func ordersNewestFirstWithTitlesAndWPM() async throws {
        let f = try await makeFixture()
        let log = try await f.db.reader.read { try MetricsQueries.sessionLog($0) }
        // Newest started_at first; s6 (11-05 20:00) is after s5 (11-05 12:00). "gone" is excluded.
        #expect(log.map(\.sessionID) == ["s9", "s8", "s7", "s6", "s5", "s4", "s3", "s2", "s1"])
        #expect(log.map(\.bookTitle) == ["", "", "Alpha", "Beta", "Alpha", "Beta", "Beta", "Alpha", "Alpha"])
        #expect(log[0].bookID == nil)
        // s9 (no book, eligible) = 300 x 60 / 180 = 100; s8 = 400 x 60 / 240 = 100; s7 = 100 x 60 / 120 = 50;
        // s6 ineligible -> nil; s5 = 250; s4 = 100; s3 = 11980 x 60 / 3594 = 200; s2 = 300; s1 = 200.
        #expect(log.map(\.wpm) == [100, 100, 50, nil, 250, 100, 200, 300, 200])
        let s1 = try #require(log.last)
        #expect(s1.startedAt == "2026-11-01T12:00:00.000Z" && s1.localDate == "2026-11-01")
        #expect(s1.activeSeconds == 300 && s1.wordsRead == 1000 && s1.pageTurns == 3)
        #expect(s1.readingMode == "paginated")
    }

    @Test func ordersByLocalDateBeforeStartedAt() async throws {
        let f = try await makeFixture()
        // A session started later in UTC but belonging to an earlier reading day (day-start-hour case).
        try await f.db.finishSession(row("late", book: f.alpha, localDate: "2026-11-10", seconds: 60, words: 10, hour: 23),
                                     timeZone: utc)
        try await f.db.writer.write { db in
            try db.execute(sql: "UPDATE fact_reading_session SET local_date = '2026-11-01', started_at = '2026-11-12T01:00:00.000Z' WHERE session_id = 'late'")
        }
        let log = try await f.db.reader.read { try MetricsQueries.sessionLog($0) }
        #expect(log.map(\.localDate) == log.map(\.localDate).sorted(by: >))
        #expect(log.map(\.sessionID).suffix(2) == ["late", "s1"])
    }

    @Test func limitAndBookFilter() async throws {
        let f = try await makeFixture()
        let limited = try await f.db.reader.read { try MetricsQueries.sessionLog($0, limit: 2) }
        #expect(limited.map(\.sessionID) == ["s9", "s8"])
        let beta = try await f.db.reader.read { [id = f.beta] in try MetricsQueries.sessionLog($0, bookID: id) }
        #expect(beta.map(\.sessionID) == ["s6", "s4", "s3"])
        let alphaLimited = try await f.db.reader.read { [id = f.alpha] in
            try MetricsQueries.sessionLog($0, bookID: id, limit: 3)
        }
        #expect(alphaLimited.map(\.sessionID) == ["s7", "s5", "s2"])
    }

    @Test func emptyDatabase() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.reader.read { try MetricsQueries.sessionLog($0) } == [])
    }
}

@Suite struct SessionLengthHistogramTests {
    @Test func boundaries() async throws {
        let f = try await makeFixture()
        let buckets = try await f.db.reader.read {
            try MetricsQueries.sessionLengthHistogram($0, from: "2026-11-01", to: "2026-11-30")
        }
        #expect(buckets.map(\.lowerMinutes) == [0, 5, 10, 20, 30, 45, 60])
        // 0: s7 (2), s8 (4), s9 (3). 5: s1 (exactly 5.0), s2 (9). 10: s5 (exactly 10). 20: none.
        // 30: s6 (exactly 30). 45: s3 (59.9). 60: s4 (61). The 120 min deleted session is excluded.
        #expect(buckets.map(\.count) == [3, 2, 1, 0, 1, 1, 1])
    }

    @Test func dateWindowAndEmpty() async throws {
        let f = try await makeFixture()
        let window = try await f.db.reader.read {
            try MetricsQueries.sessionLengthHistogram($0, from: "2026-11-02", to: "2026-11-03")
        }
        #expect(window.map(\.count) == [0, 1, 0, 0, 0, 1, 0])
        let none = try await f.db.reader.read {
            try MetricsQueries.sessionLengthHistogram($0, from: "2027-01-01", to: "2027-01-31")
        }
        #expect(none.map(\.lowerMinutes) == MetricsQueries.sessionLengthBuckets)
        #expect(none.allSatisfy { $0.count == 0 })
    }
}

@Suite struct PersonalRecordsTests {
    @Test func allRecords() async throws {
        let f = try await makeFixture()
        let records = try await f.db.reader.read {
            try MetricsQueries.personalRecords($0, today: "2026-11-10", minMinutes: 5)
        }
        #expect(records.map(\.kind) == PersonalRecordKind.allCases)
        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.kind, $0) })

        // Longest: s4, 61 min = 3660 s (the 120 min deleted session is ignored).
        #expect(byKind[.longestSession] == PersonalRecord(kind: .longestSession, value: 3660,
                                                          localDate: "2026-11-04", bookTitle: "Beta"))
        // Fastest: s5 at 250 wpm. s2 is 300 wpm but only 9 min; s6 is ineligible.
        #expect(byKind[.fastestSession] == PersonalRecord(kind: .fastestSession, value: 250,
                                                          localDate: "2026-11-05", bookTitle: "Alpha"))
        // Minutes in a day: 11-04 has 61; 11-05 has 10 + 30 = 40.
        #expect(byKind[.mostMinutesInDay] == PersonalRecord(kind: .mostMinutesInDay, value: 61,
                                                            localDate: "2026-11-04", bookTitle: nil))
        // Words in a day: 11-03 has 11980; 11-04 6100; 11-05 5500.
        #expect(byKind[.mostWordsInDay] == PersonalRecord(kind: .mostWordsInDay, value: 11980,
                                                          localDate: "2026-11-03", bookTitle: nil))
        // Pages: s3 and s5 tie on 7; the earlier one (s3) wins.
        #expect(byKind[.mostPagesInSession] == PersonalRecord(kind: .mostPagesInSession, value: 7,
                                                              localDate: "2026-11-03", bookTitle: "Beta"))
        // Streak at 5 min/day: 11-01...11-05 qualify (5, 9, 59.9, 61, 40), 11-06 is 2 min.
        #expect(byKind[.longestStreak] == PersonalRecord(kind: .longestStreak, value: 5,
                                                         localDate: nil, bookTitle: nil))
    }

    @Test func dayTiesGoToEarliest() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "Tie")
        for (id, day) in [("t2", "2026-11-02"), ("t1", "2026-11-01")] {
            try await db.finishSession(row(id, book: book, localDate: day, seconds: 1200, words: 2000, pages: 5),
                                       timeZone: utc)
        }
        let records = try await db.reader.read {
            try MetricsQueries.personalRecords($0, today: "2026-11-10", minMinutes: 5)
        }
        let byKind = Dictionary(uniqueKeysWithValues: records.map { ($0.kind, $0) })
        #expect(byKind[.mostMinutesInDay]?.localDate == "2026-11-01")
        #expect(byKind[.mostWordsInDay]?.localDate == "2026-11-01")
        #expect(byKind[.longestSession]?.localDate == "2026-11-01")
        #expect(byKind[.longestStreak]?.value == 2)
    }

    @Test func shortFastSessionAloneHasNoFastestRecord() async throws {
        let db = try AppDatabase.inMemory()
        let book = try await addBook(db, "Quick")
        try await db.finishSession(row("q", book: book, localDate: "2026-11-01", seconds: 540, words: 2700),
                                   timeZone: utc)
        let kinds = try await db.reader.read {
            try MetricsQueries.personalRecords($0, today: "2026-11-10", minMinutes: 5)
        }.map(\.kind)
        #expect(kinds == [.longestSession, .mostMinutesInDay, .mostWordsInDay, .mostPagesInSession, .longestStreak])
    }

    @Test func emptyDatabase() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.reader.read {
            try MetricsQueries.personalRecords($0, today: "2026-11-10", minMinutes: 5)
        } == [])
    }
}
