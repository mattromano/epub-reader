import Foundation
import Testing
@testable import Tracking

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_795_000_000)
private let ctx = SessionContext(bookID: "book-1", deviceID: "device-1", readingMode: "paginated",
                                 fontSize: 1.0, isFixedLayout: false)

private func page(_ w: Int) -> TrackerEvent {
    .location(LocationSample(kind: .pageTurn, wordIdx: w, chapterID: "book-1:3", progression: 0.5,
                             totalProgression: nil, locatorJSON: nil))
}

private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

/// Tracker with a book open and the first location (the seed) consumed at t0.
private func seeded() -> SessionTracker {
    var t = SessionTracker(config: TrackerConfig(timeZone: utc))
    _ = t.handle(.open(ctx), at: t0)
    _ = t.handle(page(1000), at: t0)
    return t
}

/// Output shape without the random UUIDs.
private func shape(_ outputs: [TrackerOutput]) -> String {
    outputs.map { out -> String in
        switch out {
        case .sessionEnded(let r): "end \(r.activeSeconds) \(r.wordsRead) \(r.pageTurns)"
        case .sessionDiscarded: "discard"
        case .locationEvent(let e): "ev \(e.eventType) \(e.wordsDelta ?? -1) \(e.secondsSincePrev ?? -1)"
        case .checkpoint: "ckpt"
        }
    }.joined(separator: "|")
}

@Suite struct LiveSessionStatsTests {
    @Test func noSessionBeforeOpenIsNil() {
        let t = SessionTracker(config: TrackerConfig(timeZone: utc))
        #expect(t.live(at: t0) == nil)
    }

    @Test func runningStretchCountsTowardTimerNotPace() throws {
        var t = seeded()
        _ = t.handle(page(1250), at: at(60))
        let live = try #require(t.live(at: at(90)))
        #expect(live.paceActiveSeconds == 60)
        #expect(live.elapsedActiveSeconds == 90)
        #expect(live.pageTurns == 1)
        #expect(live.wordsRead > 0)
        #expect(!live.isPaused)
        #expect(live.localDate == ReadingDay.localDate(for: t0, timeZone: utc,
                                                       dayStartHour: t.config.dayStartHour))
    }

    /// Up to the idle threshold the whole stretch counts; past it, only the median-gap tail
    /// (never wall-clock).
    @Test func runningStretchStopsAtTheIdleThreshold() throws {
        var t = seeded()
        _ = t.handle(page(1250), at: at(10))  // gaps [10]
        #expect(t.config.idleThreshold == 180)
        let atThreshold = try #require(t.live(at: at(10 + 180)))
        #expect(atThreshold.elapsedActiveSeconds == 10 + 180)
        let longStare = try #require(t.live(at: at(10 + 1000)))
        #expect(longStare.elapsedActiveSeconds == 10 + 10)
    }

    @Test func pausedTimerIsFrozen() throws {
        var t = seeded()
        _ = t.handle(page(1250), at: at(30))
        _ = t.handle(.background, at: at(40))
        let soon = try #require(t.live(at: at(45)))
        let later = try #require(t.live(at: at(40 + 500)))
        #expect(later.isPaused)
        #expect(later.elapsedActiveSeconds == soon.elapsedActiveSeconds)
        #expect(later.elapsedActiveSeconds == later.paceActiveSeconds)
    }

    @Test func endedSessionIsNil() {
        var t = seeded()
        _ = t.handle(page(1250), at: at(30))
        _ = t.handle(.background, at: at(40))
        let endAt = 40 + t.config.sessionGap + 1
        let out = t.handle(.tick, at: at(endAt))
        #expect(!out.isEmpty)
        #expect(t.live(at: at(endAt + 1)) == nil)
    }

    @Test func liveDoesNotMutate() {
        func script(callLive: Bool) -> [TrackerOutput] {
            var t = seeded()
            var out: [TrackerOutput] = []
            out += t.handle(page(1250), at: at(30))
            if callLive { _ = t.live(at: at(35)); _ = t.live(at: at(5000)) }
            out += t.handle(page(1500), at: at(60))
            out += t.handle(.background, at: at(70))
            if callLive { _ = t.live(at: at(80)) }
            out += t.handle(.tick, at: at(70 + t.config.sessionGap + 1))
            return out
        }
        #expect(shape(script(callLive: false)) == shape(script(callLive: true)))
    }

    /// Review fix: once idle, the timer shows what the idle pause will commit (the median-gap
    /// tail), so it doesn't drop back when the pause lands on the next tick.
    @Test func idleTimerMatchesTheCommittedPause() throws {
        var t = seeded()
        _ = t.handle(page(1250), at: at(40))
        _ = t.handle(page(1500), at: at(80))  // gaps 40, 40 → median 40
        let beforePause = try #require(t.live(at: at(80 + 200)))  // past the 180 s idle threshold
        #expect(beforePause.elapsedActiveSeconds == 80 + 40)
        _ = t.handle(.tick, at: at(80 + 210))  // the tracker idle-pauses
        let afterPause = try #require(t.live(at: at(80 + 220)))
        #expect(afterPause.isPaused)
        #expect(afterPause.elapsedActiveSeconds == beforePause.elapsedActiveSeconds)
    }
}
