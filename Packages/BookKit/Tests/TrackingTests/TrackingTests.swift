import Foundation
import Testing
@testable import Tracking

// MARK: - Scenario helpers

private let utc = TimeZone(identifier: "UTC")!

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

/// 2026-11-22T10:00:00Z.
private let t0 = iso("2026-11-22T10:00:00Z")

private let ctx = SessionContext(bookID: "book-1", deviceID: "device-1", readingMode: "paginated",
                                 fontSize: 1.0, isFixedLayout: false)

private func config(_ tz: TimeZone = utc) -> TrackerConfig { TrackerConfig(timeZone: tz) }

private func page(_ w: Int?, tp: Double? = nil) -> TrackerEvent {
    .location(LocationSample(kind: .pageTurn, wordIdx: w, chapterID: "book-1:3", progression: 0.5,
                             totalProgression: tp, locatorJSON: w.map { "{\"w\":\($0)}" }))
}

private func scroll(_ w: Int?, tp: Double) -> TrackerEvent {
    .location(LocationSample(kind: .scroll, wordIdx: w, chapterID: "book-1:3", progression: 0.5,
                             totalProgression: tp, locatorJSON: nil))
}

private func jump(_ w: Int?) -> TrackerEvent {
    .location(LocationSample(kind: .jump, wordIdx: w, chapterID: "book-1:9", progression: 0.1,
                             totalProgression: nil, locatorJSON: nil))
}

private typealias Step = (Double, TrackerEvent)

private struct Run {
    var tracker: SessionTracker
    var outputs: [TrackerOutput]
    /// Outputs per step, aligned with the script.
    var perStep: [[TrackerOutput]]

    var ended: [SessionRow] {
        outputs.compactMap { if case .sessionEnded(let r) = $0 { r } else { nil } }
    }
    var discarded: [String] {
        outputs.compactMap { if case .sessionDiscarded(let id) = $0 { id } else { nil } }
    }
    var events: [LocationEventRow] {
        outputs.compactMap { if case .locationEvent(let r) = $0 { r } else { nil } }
    }
    var checkpoints: [SessionDraft] {
        outputs.compactMap { if case .checkpoint(let d) = $0 { d } else { nil } }
    }
}

private func run(_ steps: [Step], config: TrackerConfig = config(), start: Date = t0,
                 context: SessionContext = ctx) -> Run {
    var tracker = SessionTracker(config: config)
    var all: [TrackerOutput] = []
    var perStep: [[TrackerOutput]] = []
    for (offset, event) in steps {
        let out = tracker.handle(event, at: start.addingTimeInterval(offset))
        all += out
        perStep.append(out)
    }
    return Run(tracker: tracker, outputs: all, perStep: perStep)
}

private func open(_ c: SessionContext = ctx) -> Step { (0, .open(c)) }

/// open@0, seed@0 (w=1000), then page turns every 30 s, +250 words each, `count` times.
private func steadyPages(count: Int, from: Int = 1000, every: Double = 30, startingAt: Double = 0) -> [Step] {
    (1...count).map { i in (startingAt + Double(i) * every, page(from + 250 * i)) }
}

// MARK: - Config

@Suite struct TrackerConfigTests {
    @Test func specDefaults() {
        let config = TrackerConfig(timeZone: TimeZone(identifier: "UTC")!)
        #expect(config.idleThreshold == 180)
        #expect(config.sessionGap == 300)
        #expect(config.dayStartHour == 4)
    }
}

// MARK: - Active time and words

@Suite struct SteadyReadingTests {
    @Test func steadyPageTurnsEvery30s() throws {
        // 10 page turns, close 15 s after the last one: tail = min(15, median 30) = 15.
        let r = run([open(), (0, page(1000, tp: 0.10))] + steadyPages(count: 10) + [(315, .close)])
        let s = try #require(r.ended.first)
        #expect(r.ended.count == 1)
        #expect(s.activeSeconds == 315)
        #expect(s.wallSeconds == 315)
        #expect(s.wordsRead == 2500)
        #expect(s.pageTurns == 10)
        #expect(s.jumpCount == 0)
        #expect(s.startWordIdx == 1000)
        #expect(s.endWordIdx == 3500)
        #expect(s.startTotalProgression == 0.10)
        #expect(s.startLocatorJSON == "{\"w\":1000}")
        #expect(s.endLocatorJSON == "{\"w\":3500}")
        #expect(s.endReason == .closed)
        #expect(s.isPaceEligible)
        #expect(s.startedAt == t0)
        #expect(s.endedAt == t0.addingTimeInterval(315))
        #expect(s.localDate == "2026-11-22")
        #expect(s.localStartHour == 10)
        #expect(s.tzOffsetMinutes == 0)
        #expect(s.bookID == "book-1")
        #expect(s.deviceID == "device-1")
        #expect(s.readingMode == "paginated")
        #expect(s.fontSize == 1.0)

        let types = r.events.map(\.eventType)
        #expect(types == [.open] + Array(repeating: .pageTurn, count: 10) + [.close])
        #expect(r.events.filter(\.isCounted).count == 10)
        #expect(r.events.first?.wordsDelta == nil)
        #expect(r.events[1].wordsDelta == 250)
        #expect(r.events[1].secondsSincePrev == 30)
        #expect(Set(r.events.map(\.sessionID)) == [s.sessionID])
        #expect(r.tracker.currentSessionID == nil)
    }
}

@Suite struct IdleTests {
    private static let script: [Step] = [open(), (0, page(1000))] + steadyPages(count: 3)  // active 90
        + [(120, .tick), (150, .tick), (180, .tick), (210, .tick), (240, .tick), (270, .tick),
           (300, .tick)]  // 300 − 90 > 180 → idle pause at 90 + median 30 = 120
        + [(330, page(2000)), (360, page(2250)), (360, .close)]

    @Test func idleGapIsCappedAndPausesOnTick() throws {
        let r = run(Self.script)
        // Ticks 120…270 are still within the threshold (270 − 90 = 180, not > 180).
        let tick270 = r.perStep[10]
        #expect(!tick270.contains { if case .locationEvent = $0 { true } else { false } })
        // Tick at 300 pauses at last event + tail.
        let tick300 = r.perStep[11]
        let pause = try #require(tick300.compactMap { if case .locationEvent(let e) = $0 { e } else { nil } }.first)
        #expect(pause.eventType == .pause)
        #expect(pause.occurredAt == t0.addingTimeInterval(120))
        #expect(tick300.contains { if case .checkpoint(let d) = $0 { d.lastCheckpointAt == t0.addingTimeInterval(120) } else { false } })

        // Page at 330 resumes (210 s after the pause ≤ 300) in the same session.
        let s = try #require(r.ended.first)
        #expect(r.ended.count == 1)
        #expect(s.activeSeconds == 150)  // 90 + tail 30 + 0 (resume→page) + 30
        #expect(s.wordsRead == 1250)
        #expect(s.pageTurns == 5)
        #expect(s.wallSeconds == 360)
        let resumedTurn = try #require(r.events.first { $0.occurredAt == t0.addingTimeInterval(330) && $0.eventType == .pageTurn })
        #expect(resumedTurn.isCounted)
        #expect(resumedTurn.secondsSincePrev == 240)
        #expect(r.events.map(\.eventType).contains(.resume))
    }

    @Test func idleResultDoesNotDependOnTicks() throws {
        let withTicks = run(Self.script)
        let withoutTicks = run(Self.script.filter { if case .tick = $0.1 { false } else { true } })
        func norm(_ e: LocationEventRow) -> LocationEventRow {
            var e = e; e.eventID = ""; e.sessionID = ""; return e
        }
        func norm(_ s: SessionRow) -> SessionRow { var s = s; s.sessionID = ""; return s }
        #expect(withTicks.events.map(norm) == withoutTicks.events.map(norm))
        #expect(withTicks.ended.map(norm) == withoutTicks.ended.map(norm))
    }

    @Test func lateLocationPausesEndsAndRestartsInOneCall() throws {
        // No ticks: page at 500 finds 410 s idle → pause at 120; 380 s > gap → end, new session.
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3) + [(500, page(2000))])
        let last = r.perStep[5]
        #expect(last.count == 4)
        guard last.count == 4,
              case .locationEvent(let pause) = last[0],
              case .checkpoint(let draft) = last[1],
              case .sessionEnded(let old) = last[2],
              case .locationEvent(let seed) = last[3] else {
            Issue.record("unexpected outputs \(last)"); return
        }
        #expect(pause.eventType == .pause)
        #expect(pause.occurredAt == t0.addingTimeInterval(120))
        #expect(draft.lastCheckpointAt == t0.addingTimeInterval(120))
        #expect(old.endReason == .idleTimeout)
        #expect(old.endedAt == t0.addingTimeInterval(120))
        #expect(old.activeSeconds == 120)
        #expect(old.wordsRead == 750)
        #expect(seed.eventType == .open)
        #expect(seed.sessionID != old.sessionID)
        #expect(seed.sessionID == r.tracker.currentSessionID)
    }

    @Test func pausedLongerThanGapEndsWithIdleTimeoutOnTick() throws {
        // Idle pause at 120; tick at 421 is > 300 s after it → ends at the pause time.
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3) + [(300, .tick), (421, .tick)])
        let s = try #require(r.ended.first)
        #expect(s.endReason == .idleTimeout)
        #expect(s.endedAt == t0.addingTimeInterval(120))
        #expect(s.activeSeconds == 120)
        #expect(r.tracker.currentSessionID == nil)
    }
}

@Suite struct BackgroundTests {
    @Test func backgroundFourMinutesContinuesSameSession() throws {
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3)
                    + [(100, .background), (340, .foreground), (370, page(2000)), (400, page(2250)), (400, .close)])
        let bg = r.perStep[5]
        #expect(bg.contains { if case .locationEvent(let e) = $0 { e.eventType == .pause } else { false } })
        #expect(bg.contains { if case .checkpoint(let d) = $0 { d.lastCheckpointAt == t0.addingTimeInterval(100) } else { false } })
        let fg = r.perStep[6]
        #expect(fg.count == 1)
        #expect(fg.contains { if case .locationEvent(let e) = $0 { e.eventType == .resume } else { false } })

        let s = try #require(r.ended.first)
        #expect(r.ended.count == 1)
        #expect(r.discarded.isEmpty)
        #expect(s.activeSeconds == 160)  // 90 + tail 10 + (340→370) 30 + 30; 240 s background excluded
        #expect(s.wallSeconds == 400)
        #expect(s.wordsRead == 1250)
        #expect(Set(r.events.map(\.sessionID)).count == 1)
    }

    @Test func backgroundSixMinutesStartsNewSession() throws {
        var tracker = SessionTracker(config: config())
        var outputs: [TrackerOutput] = []
        for (o, e) in [open(), (0, page(1000))] + steadyPages(count: 3) + [(100, .background)] {
            outputs += tracker.handle(e, at: t0.addingTimeInterval(o))
        }
        let firstID = try #require(tracker.currentSessionID)

        let fg = tracker.handle(.foreground, at: t0.addingTimeInterval(460))
        let old = try #require(fg.compactMap { if case .sessionEnded(let r) = $0 { r } else { nil } }.first)
        #expect(fg.count == 1)
        #expect(old.sessionID == firstID)
        #expect(old.endReason == .backgrounded)
        #expect(old.endedAt == t0.addingTimeInterval(100))
        #expect(old.activeSeconds == 100)
        #expect(old.wallSeconds == 100)
        #expect(old.wordsRead == 750)

        let secondID = try #require(tracker.currentSessionID)
        #expect(secondID != firstID)

        let seed = tracker.handle(page(2000), at: t0.addingTimeInterval(470))
        guard case .locationEvent(let seedRow) = try #require(seed.first) else { Issue.record("no row"); return }
        #expect(seedRow.eventType == .open)
        #expect(seedRow.sessionID == secondID)
        #expect(seedRow.wordsDelta == nil)

        _ = tracker.handle(page(2250), at: t0.addingTimeInterval(500))
        _ = tracker.handle(page(2500), at: t0.addingTimeInterval(530))
        let closed = tracker.handle(.close, at: t0.addingTimeInterval(530))
        let s = try #require(closed.compactMap { if case .sessionEnded(let r) = $0 { r } else { nil } }.first)
        #expect(s.sessionID == secondID)
        #expect(s.startedAt == t0.addingTimeInterval(460))
        #expect(s.activeSeconds == 70)  // (460→470) 10 + 30 + 30
        #expect(s.wordsRead == 500)
        #expect(s.startWordIdx == 2000)
    }
}

@Suite struct JumpTests {
    @Test func tocJumpNotCountedAndResetsBaseline() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)), (60, jump(50_000)), (90, page(50_250)),
                     (120, page(50_500)), (120, .close)])
        let s = try #require(r.ended.first)
        #expect(s.wordsRead == 750)
        #expect(s.jumpCount == 1)
        #expect(s.pageTurns == 3)
        #expect(s.activeSeconds == 120)
        let j = try #require(r.events.first { $0.eventType == .jump })
        #expect(!j.isCounted)
        #expect(j.wordsDelta == 48_750)
        let after = try #require(r.events.first { $0.wordIdx == 50_250 })
        #expect(after.wordsDelta == 250)
        #expect(after.isCounted)
    }

    @Test func twoConsecutiveJumpSamples() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)), (40, jump(9000)), (41, jump(9000)),
                     (71, page(9250)), (101, page(9500)), (101, .close)])
        let s = try #require(r.ended.first)
        #expect(s.jumpCount == 2)
        #expect(s.wordsRead == 750)
        let jumps = r.events.filter { $0.eventType == .jump }
        #expect(jumps.map(\.wordsDelta) == [7750, 0])
        #expect(jumps.allSatisfy { !$0.isCounted })
    }

    @Test func preferencesChangeWithJumpCountsNoWords() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)),
                     (40, .contextChanged(readingMode: "scroll", fontSize: 1.2)), (40, jump(1260)),
                     (70, page(1510)), (100, page(1760)), (100, .close)])
        let s = try #require(r.ended.first)
        #expect(s.wordsRead == 750)  // 250 + 250 + 250; the +10 reflow jump is not counted
        #expect(s.jumpCount == 1)
        #expect(s.readingMode == "scroll")
        #expect(s.fontSize == 1.2)
        let j = try #require(r.events.first { $0.eventType == .jump })
        #expect(!j.isCounted)
        #expect(j.wordsDelta == 10)
    }

    @Test func backwardsPagingCountsZeroButAddsActiveTime() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)), (60, page(1000)), (90, page(750)), (90, .close)])
        let s = try #require(r.ended.first)
        #expect(s.wordsRead == 250)
        #expect(s.activeSeconds == 90)
        #expect(s.pageTurns == 3)
        #expect(s.jumpCount == 0)
        let back = r.events.filter { ($0.wordsDelta ?? 0) < 0 }
        #expect(back.map(\.wordsDelta) == [-250, -250])
        #expect(back.allSatisfy { !$0.isCounted })
    }

    @Test func overCapAndOverRateDeltasNotCounted() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)),
                     (40, page(6250)),   // +5000 in 10 s: above the 1500 cap → jump, baseline reset
                     (50, page(7250)),   // +1000 in 10 s = 6000 WPM: under cap, over rate
                     (80, page(7500)),   // +250 in 30 s: counted
                     (80, .close)])
        let s = try #require(r.ended.first)
        #expect(s.wordsRead == 500)
        #expect(s.jumpCount == 1)
        #expect(s.pageTurns == 4)
        #expect(s.activeSeconds == 80)
        let overCap = try #require(r.events.first { $0.wordIdx == 6250 })
        #expect(overCap.wordsDelta == 5000)
        #expect(!overCap.isCounted)
        let overRate = try #require(r.events.first { $0.wordIdx == 7250 })
        #expect(overRate.wordsDelta == 1000)
        #expect(!overRate.isCounted)
        let next = try #require(r.events.first { $0.wordIdx == 7500 })
        #expect(next.wordsDelta == 250)
        #expect(next.isCounted)
    }
}

@Suite struct DiscardTests {
    @Test func twentySecondSessionIsDiscarded() throws {
        let r = run([open(), (0, page(1000)), (10, page(1250)), (20, page(1500)), (20, .close)])
        #expect(r.ended.isEmpty)
        #expect(r.discarded.count == 1)
        #expect(r.discarded.first == r.events.first?.sessionID)
    }

    @Test func onlyJumpsIsDiscarded() throws {
        let r = run([open(), (0, page(1000)), (30, jump(5000)), (60, jump(9000)), (90, .close)])
        #expect(r.ended.isEmpty)
        #expect(r.discarded.count == 1)
    }
}

@Suite struct ScrollThrottleTests {
    @Test func dropsOnTimeRuleAndProgressionRule() throws {
        let r = run([open(),
                     (0, scroll(1000, tp: 0.100)),   // seed
                     (1, scroll(1100, tp: 0.110)),   // 1 s < 2 s → dropped (time rule)
                     (5, scroll(1110, tp: 0.102)),   // Δtp 0.002 < 0.005 → dropped (progression rule)
                     (10, scroll(1200, tp: 0.120)),  // emitted: +200 from the seed in 10 s
                     (20, scroll(1400, tp: 0.140)),
                     (30, scroll(1600, tp: 0.160)),
                     (30, .close)])
        #expect(r.events.map(\.eventType) == [.open, .scroll, .scroll, .scroll, .close])
        let first = r.events[1]
        #expect(first.wordIdx == 1200)
        #expect(first.wordsDelta == 200)  // dropped samples didn't move the baseline
        #expect(first.secondsSincePrev == 10)
        #expect(first.isCounted)
        let s = try #require(r.ended.first)
        #expect(s.wordsRead == 600)
        #expect(s.activeSeconds == 30)
        #expect(s.pageTurns == 0)
    }

    @Test func droppedScrollStillCountsAsActivityForIdle() throws {
        // Emitted at 0 and 100; throttled samples every 1.5 s keep it from going idle at the 200 s tick.
        var steps: [Step] = [open(), (0, scroll(1000, tp: 0.10)), (100, scroll(1200, tp: 0.12))]
        steps.append((190, scroll(1201, tp: 0.1201)))  // dropped (progression)
        steps.append((300, .tick))  // 300 − 190 = 110 ≤ 180 → still reading
        let r = run(steps)
        #expect(!r.events.contains { $0.eventType == .pause })
    }
}

// MARK: - Checkpoint and recovery

@Suite struct RecoveryTests {
    @Test func checkpointThenRecoverEndsAtLastCheckpoint() throws {
        let r = run([open(), (0, page(1000)), (30, page(1250)), (30, .tick), (60, page(1500)), (60, .tick),
                     (90, page(1750)), (90, .tick), (120, .tick)])
        #expect(r.checkpoints.map(\.lastCheckpointAt) == [30, 60, 90, 120].map { t0.addingTimeInterval($0) })
        let draft = try #require(r.checkpoints.last)
        #expect(draft.sessionID == r.tracker.currentSessionID)
        #expect(draft.bookID == "book-1")
        #expect(draft.startedAt == t0)
        let s = try #require(SessionTracker.recover(draft))
        #expect(s.endReason == .crashRecovered)
        #expect(s.endedAt == t0.addingTimeInterval(120))
        #expect(s.activeSeconds == 120)  // 90 + tail min(30, median 30)
        #expect(s.wallSeconds == 120)
        #expect(s.wordsRead == 750)
        #expect(s.sessionID == draft.sessionID)
    }

    @Test func recoverAfterBackgroundCheckpointDoesNotDoubleTail() throws {
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3) + [(100, .background)])
        let draft = try #require(r.checkpoints.last)
        let s = try #require(SessionTracker.recover(draft))
        #expect(s.activeSeconds == 100)
        #expect(s.endedAt == t0.addingTimeInterval(100))
    }

    @Test func recoverTooShortReturnsNil() throws {
        let r = run([open(), (0, page(1000)), (10, page(1250)), (15, .background)])
        let draft = try #require(r.checkpoints.last)
        #expect(SessionTracker.recover(draft) == nil)
    }

    @Test func recoverGarbageReturnsNil() {
        let draft = SessionDraft(sessionID: "x", bookID: "b", startedAt: t0, lastCheckpointAt: t0,
                                 stateJSON: "{not json")
        #expect(SessionTracker.recover(draft) == nil)
    }
}

// MARK: - Reading day

@Suite struct ReadingDayTests {
    @Test func dayStartBoundary() {
        #expect(ReadingDay.localDate(for: iso("2026-11-22T03:59:00Z"), timeZone: utc, dayStartHour: 4) == "2026-11-21")
        #expect(ReadingDay.localDate(for: iso("2026-11-22T04:00:00Z"), timeZone: utc, dayStartHour: 4) == "2026-11-22")
        let ny = TimeZone(identifier: "America/New_York")!
        #expect(ReadingDay.localDate(for: iso("2026-11-22T08:59:00Z"), timeZone: ny, dayStartHour: 4) == "2026-11-21")
        #expect(ReadingDay.localDate(for: iso("2026-11-22T09:00:00Z"), timeZone: ny, dayStartHour: 4) == "2026-11-22")
        #expect(ReadingDay.localDate(for: iso("2026-11-22T00:30:00Z"), timeZone: utc, dayStartHour: 0) == "2026-11-22")
    }

    @Test func sessionResumedAfterSixMinutesAcross4amGetsNextLocalDate() throws {
        let start = iso("2026-11-22T03:55:00Z")
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3)
                    + [(100, .background),       // 03:56:40
                       (460, .foreground),       // 04:02:40: 360 s > gap → new session
                       (470, page(2000)), (500, page(2250)), (530, page(2500)), (530, .close)],
                    start: start)
        #expect(r.ended.count == 2)
        #expect(r.ended[0].localDate == "2026-11-21")
        #expect(r.ended[0].localStartHour == 3)
        #expect(r.ended[1].localDate == "2026-11-22")
        #expect(r.ended[1].localStartHour == 4)
        #expect(r.ended[0].sessionID != r.ended[1].sessionID)
    }

    @Test func tzOffsetFromConfiguredZone() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let r = run([open(), (0, page(1000))] + steadyPages(count: 3) + [(90, .close)], config: config(ny))
        let s = try #require(r.ended.first)
        #expect(s.tzOffsetMinutes == -300)
        #expect(s.localStartHour == 5)
        #expect(s.localDate == "2026-11-22")
    }
}

// MARK: - Pace eligibility

@Suite struct PaceEligibilityTests {
    private let script: [Step] = [(0, page(1000))] + steadyPages(count: 4) + [(120, .close)]

    @Test func eligibleWhenIndexedReflowableLongEnough() throws {
        let s = try #require(run([open()] + script).ended.first)
        #expect(s.activeSeconds == 120)
        #expect(s.wordsRead == 1000)
        #expect(s.isPaceEligible)
    }

    @Test func fixedLayoutIsNeverEligible() throws {
        var fixed = ctx
        fixed.isFixedLayout = true
        let s = try #require(run([open(fixed)] + script).ended.first)
        #expect(!s.isPaceEligible)
    }

    @Test func unindexedIsNotEligible() throws {
        let steps: [Step] = [open(), (0, page(nil)), (30, page(nil)), (60, page(nil)), (90, page(nil)),
                             (120, page(nil)), (120, .close)]
        let s = try #require(run(steps).ended.first)
        #expect(s.wordsRead == 0)
        #expect(s.startWordIdx == nil)
        #expect(!s.isPaceEligible)
    }

    @Test func underSixtySecondsIsNotEligible() throws {
        let steps: [Step] = [open(), (0, page(1000)), (25, page(1250)), (50, page(1500)), (50, .close)]
        let s = try #require(run(steps).ended.first)
        #expect(s.activeSeconds == 50)
        #expect(s.wordsRead == 500)
        #expect(!s.isPaceEligible)
    }
}
