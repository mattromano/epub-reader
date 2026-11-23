import Foundation
import Testing
@testable import WidgetData

// M6: the widget reads a JSON snapshot and must stay correct after the reading day rolls over.

private let utc = TimeZone(identifier: "UTC")!

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

private func snapshot(today: String = "2026-11-22", minutes: Double = 18, streak: Int = 6,
                      includesToday: Bool = true) -> WidgetSnapshot {
    WidgetSnapshot(
        generatedAt: date("2026-11-22T20:00:00Z"), today: today, dayStartHour: 4, timeZoneID: "UTC",
        todayMinutes: minutes, goalMinutes: 30, streakMinMinutes: 5, currentStreak: streak,
        streakIncludesToday: includesToday,
        continueReading: .init(bookID: "b1", title: "Middlemarch", authors: "George Eliot",
                               coverRelpath: "Covers/b1.jpg", percentComplete: 0.42, bookMinutesLeft: 312))
}

@Suite struct WidgetDisplayTests {
    @Test func sameReadingDayShowsSnapshotAsIs() {
        let state = snapshot().display(at: date("2026-11-23T02:00:00Z")) // 02:00 is still the 22nd's reading day
        #expect(state.todayMinutes == 18)
        #expect(state.currentStreak == 6)
        #expect(state.streakIsAtRisk == false)
        #expect(state.goalProgress == 0.6)
    }

    @Test func nextDayAfterQualifyingTodayKeepsStreakAtRisk() {
        let state = snapshot().display(at: date("2026-11-23T09:00:00Z"))
        #expect(state.todayMinutes == 0)
        #expect(state.currentStreak == 6)       // alive through yesterday
        #expect(state.streakIsAtRisk == true)
    }

    @Test func nextDayWhenTodayDidNotQualifyBreaksStreak() {
        // Snapshot day hadn't qualified yet: the streak was alive only through the day before.
        let state = snapshot(minutes: 2, streak: 6, includesToday: false).display(at: date("2026-11-23T09:00:00Z"))
        #expect(state.currentStreak == 0)
        #expect(state.todayMinutes == 0)
    }

    @Test func twoDaysLaterEverythingResets() {
        let state = snapshot().display(at: date("2026-11-24T12:00:00Z"))
        #expect(state.currentStreak == 0)
        #expect(state.todayMinutes == 0)
        #expect(state.streakIsAtRisk == false)
    }

    @Test func unqualifiedTodayIsAtRisk() {
        let state = snapshot(minutes: 2, streak: 6, includesToday: false).display(at: date("2026-11-22T21:00:00Z"))
        #expect(state.currentStreak == 6)
        #expect(state.streakIsAtRisk == true)
    }

    @Test func noGoalMeansNoProgress() {
        var s = snapshot()
        s.goalMinutes = nil
        #expect(s.display(at: date("2026-11-22T21:00:00Z")).goalProgress == nil)
        s.goalMinutes = 10
        #expect(s.display(at: date("2026-11-22T21:00:00Z")).goalProgress == 1) // capped
    }

    @Test func nextDayStartFollowsDayStartHour() {
        let s = snapshot()
        #expect(s.nextDayStart(after: date("2026-11-22T20:00:00Z")) == date("2026-11-23T04:00:00Z"))
        #expect(s.nextDayStart(after: date("2026-11-23T03:59:00Z")) == date("2026-11-23T04:00:00Z"))
        #expect(s.nextDayStart(after: date("2026-11-23T04:00:00Z")) == date("2026-11-24T04:00:00Z"))
    }

    @Test func nextDayStartAcrossDSTUsesLocalMidnightPlusHours() throws {
        var s = snapshot()
        s.timeZoneID = "America/New_York"
        // US DST ends 2026-11-01 at 02:00 local. The tracker's rule is "local date of now − 4 h",
        // so the day turns 4 absolute hours after local midnight (04:00Z EDT) = 08:00Z, the same
        // boundary the aggregates use (not 04:00 EST wall clock, 09:00Z).
        #expect(s.nextDayStart(after: date("2026-10-31T12:00:00Z")) == date("2026-11-01T08:00:00Z"))
    }

    @Test func roundTripsThroughFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(WidgetSnapshot.read(from: dir) == nil)
        try snapshot().write(to: dir)
        #expect(WidgetSnapshot.read(from: dir) == snapshot())
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(WidgetSnapshot.fileName))
        #expect(WidgetSnapshot.read(from: dir) == nil)
    }

    @Test func deepLinkRoundTrips() {
        let url = WidgetLink.openBook("ABC-123")
        #expect(url.absoluteString == "margins://open?book=ABC-123")
        #expect(WidgetLink.bookID(from: url) == "ABC-123")
        #expect(WidgetLink.bookID(from: URL(string: "margins://other")!) == nil)
        #expect(WidgetLink.bookID(from: URL(fileURLWithPath: "/tmp/a.epub")) == nil)
    }
}
