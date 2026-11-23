import Foundation
import Testing
import Tracking
@testable import Metrics

private func live(date: String = "2026-11-22", elapsed: Double = 1421, pace: Double = 1200,
                  words: Int = 5200, turns: Int = 31, paused: Bool = false) -> LiveSessionStats {
    LiveSessionStats(localDate: date, elapsedActiveSeconds: elapsed, paceActiveSeconds: pace,
                     wordsRead: words, pageTurns: turns, isPaused: paused)
}

private func baseline(usual: Double? = 240, finished: Double = 0, goal: Double? = 30) -> ReaderStatsBaseline {
    ReaderStatsBaseline(today: "2026-11-22", usualWPM: usual, todayFinishedSeconds: finished, goalMinutes: goal)
}

private func input(live: LiveSessionStats? = live(),
                   baseline: ReaderStatsBaseline? = baseline(),
                   timeLeft: TimeLeft? = TimeLeft(chapterMinutes: 12, bookMinutes: 250),
                   progression: Double? = 0.41, scroll: Bool = false) -> ReaderStatsInput {
    ReaderStatsInput(live: live, baseline: baseline, timeLeft: timeLeft, bookProgression: progression,
                     isScrollMode: scroll)
}

private struct Row: Sendable, CustomTestStringConvertible {
    var name: String
    var stat: ReaderStat
    var input: ReaderStatsInput
    var full: String?
    var compact: String?
    var testDescription: String { name }
}

private let minus = "\u{2212}"
private let rows: [Row] = [
    Row(name: "chapter", stat: .chapterTimeLeft, input: input(), full: "12 min left in chapter", compact: "12 min left"),
    Row(name: "chapter nil", stat: .chapterTimeLeft, input: input(timeLeft: nil), full: nil, compact: nil),
    Row(name: "chapter unknown", stat: .chapterTimeLeft,
        input: input(timeLeft: TimeLeft(chapterMinutes: nil, bookMinutes: 5)), full: nil, compact: nil),
    Row(name: "chapter <1", stat: .chapterTimeLeft,
        input: input(timeLeft: TimeLeft(chapterMinutes: 0.2, bookMinutes: nil)),
        full: "<1 min left in chapter", compact: "<1 min left"),
    Row(name: "book", stat: .bookTimeLeft, input: input(), full: "4 h 10 m left in book", compact: "4 h 10 m in book"),
    Row(name: "book hour", stat: .bookTimeLeft,
        input: input(timeLeft: TimeLeft(chapterMinutes: nil, bookMinutes: 60)),
        full: "1 h left in book", compact: "1 h in book"),
    Row(name: "book nil", stat: .bookTimeLeft,
        input: input(timeLeft: TimeLeft(chapterMinutes: 3, bookMinutes: nil)), full: nil, compact: nil),
    Row(name: "percent", stat: .bookPercent, input: input(), full: "41%", compact: "41%"),
    Row(name: "percent nil", stat: .bookPercent, input: input(progression: nil), full: nil, compact: nil),
    Row(name: "time", stat: .sessionTime, input: input(), full: "23:41", compact: "23:41"),
    Row(name: "time hour", stat: .sessionTime, input: input(live: live(elapsed: 3761.9)), full: "1:02:41", compact: "1:02:41"),
    Row(name: "time nil", stat: .sessionTime, input: input(live: nil), full: nil, compact: nil),
    // 5200 words / 20 min = 260 wpm
    Row(name: "wpm", stat: .sessionWPM, input: input(), full: "260 wpm", compact: "260 wpm"),
    Row(name: "wpm nil", stat: .sessionWPM, input: input(live: nil), full: nil, compact: nil),
    // 260 vs 240 = +8.33% -> +8%
    Row(name: "vs usual up", stat: .wpmVsUsual, input: input(), full: "+8% vs usual", compact: "+8%"),
    // 5820 words / 20 min = 291 wpm vs 300 -> -3%
    Row(name: "vs usual down", stat: .wpmVsUsual,
        input: input(live: live(words: 5820), baseline: baseline(usual: 300)),
        full: "\(minus)3% vs usual", compact: "\(minus)3%"),
    Row(name: "vs usual same", stat: .wpmVsUsual,
        input: input(live: live(words: 4800), baseline: baseline(usual: 240)),
        full: "same as usual", compact: "\u{00B1}0%"),
    Row(name: "vs usual no baseline", stat: .wpmVsUsual, input: input(baseline: nil), full: nil, compact: nil),
    Row(name: "vs usual no usual", stat: .wpmVsUsual, input: input(baseline: baseline(usual: nil)), full: nil, compact: nil),
    Row(name: "vs usual no live", stat: .wpmVsUsual, input: input(live: nil), full: nil, compact: nil),
    Row(name: "words", stat: .sessionWords, input: input(live: live(words: 6020)), full: "6,020 words", compact: "6,020 words"),
    Row(name: "one word", stat: .sessionWords, input: input(live: live(words: 1)), full: "1 word", compact: "1 word"),
    Row(name: "words nil", stat: .sessionWords, input: input(live: nil), full: nil, compact: nil),
    Row(name: "pages", stat: .sessionPages, input: input(), full: "31 pages", compact: "31 pages"),
    Row(name: "one page", stat: .sessionPages, input: input(live: live(turns: 1)), full: "1 page", compact: "1 page"),
    Row(name: "pages scroll", stat: .sessionPages, input: input(scroll: true), full: nil, compact: nil),
    Row(name: "pages nil", stat: .sessionPages, input: input(live: nil), full: nil, compact: nil),
    // 26 pages / 20 min = 1.3
    Row(name: "ppm", stat: .pagesPerMinute, input: input(live: live(turns: 26)), full: "1.3 pages/min", compact: "1.3 pages/min"),
    Row(name: "ppm scroll", stat: .pagesPerMinute, input: input(scroll: true), full: nil, compact: nil),
    Row(name: "ppm nil", stat: .pagesPerMinute, input: input(live: nil), full: nil, compact: nil),
    // 800 s finished + 300 s live = 1100 s -> 18 min
    Row(name: "today goal", stat: .todayVsGoal,
        input: input(live: live(elapsed: 300), baseline: baseline(finished: 800)),
        full: "18 / 30 min today", compact: "18/30 min"),
    Row(name: "today nil", stat: .todayVsGoal, input: input(baseline: nil), full: nil, compact: nil),
]

@Suite struct ReaderStatsCalculatorTests {
    @Test(arguments: rows) fileprivate func table(_ row: Row) {
        #expect(ReaderStatsCalculator.text(for: row.stat, input: row.input, style: .full) == row.full)
        #expect(ReaderStatsCalculator.text(for: row.stat, input: row.input, style: .compact) == row.compact)
    }

    @Test func gatedSpeedShowsDash() {
        for l in [live(pace: 119, words: 5200), live(pace: 1200, words: 149)] {
            let i = input(live: l)
            #expect(ReaderStatsCalculator.text(for: .sessionWPM, input: i) == "\u{2014} wpm")
            #expect(ReaderStatsCalculator.text(for: .sessionWPM, input: i, style: .compact) == "\u{2014} wpm")
            #expect(ReaderStatsCalculator.text(for: .wpmVsUsual, input: i) == nil)
            #expect(ReaderStatsCalculator.text(for: .pagesPerMinute, input: i) == "\u{2014} pages/min")
        }
        // At the thresholds the speed shows: 150 words / 2 min = 75 wpm.
        let ok = input(live: live(pace: 120, words: 150))
        #expect(ReaderStatsCalculator.text(for: .sessionWPM, input: ok) == "75 wpm")
    }

    @Test func wpmRoundsToNearestFive() {
        // 5240 words in 20 min = 262 wpm; 5260 = 263 wpm.
        #expect(ReaderStatsCalculator.text(for: .sessionWPM, input: input(live: live(words: 5240))) == "260 wpm")
        #expect(ReaderStatsCalculator.text(for: .sessionWPM, input: input(live: live(words: 5260))) == "265 wpm")
    }

    @Test func todayExcludesLiveSessionFromAnotherDay() {
        let base = baseline(finished: 600)
        let other = input(live: live(date: "2026-11-21", elapsed: 1800), baseline: base)
        #expect(ReaderStatsCalculator.text(for: .todayVsGoal, input: other) == "10 / 30 min today")
        let same = input(live: live(date: "2026-11-22", elapsed: 1800), baseline: base)
        #expect(ReaderStatsCalculator.text(for: .todayVsGoal, input: same) == "40 / 30 min today")
    }

    @Test func todayWithoutGoal() {
        let i = input(live: nil, baseline: baseline(finished: 1080, goal: nil))
        #expect(ReaderStatsCalculator.text(for: .todayVsGoal, input: i) == "18 min today")
        #expect(ReaderStatsCalculator.text(for: .todayVsGoal, input: i, style: .compact) == "18 min")
    }

    @Test func scrollModeHidesPages() {
        let i = input(scroll: true)
        #expect(ReaderStatsCalculator.values([.sessionPages, .pagesPerMinute, .sessionWords], input: i).map(\.stat)
            == [.sessionWords])
    }

    @Test func nothingAvailableGivesEmptyValues() {
        let i = input(live: nil, baseline: nil, timeLeft: nil, progression: nil)
        #expect(ReaderStatsCalculator.values(ReaderStat.allCases, input: i).isEmpty)
    }

    @Test func valuesKeepOrder() {
        let v = ReaderStatsCalculator.values([.bookPercent, .chapterTimeLeft, .sessionTime], input: input())
        #expect(v.map(\.stat) == [.bookPercent, .chapterTimeLeft, .sessionTime])
        #expect(v.map(\.text) == ["41%", "12 min left in chapter", "23:41"])
    }
}
