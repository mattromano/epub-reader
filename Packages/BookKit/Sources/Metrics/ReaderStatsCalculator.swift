import Foundation
import Tracking

/// DB-backed numbers the live stats are measured against; reloaded on open, when a session row
/// lands, and on chapter change.
public struct ReaderStatsBaseline: Sendable, Equatable {
    /// Reading day the baseline was computed for.
    public var today: String
    /// Book pace (falls back to rolling pace), WPM; nil when there is no pace yet.
    public var usualWPM: Double?
    /// Σ active_seconds of finished sessions on `today`.
    public var todayFinishedSeconds: Double
    /// Current `daily_minutes` goal target; nil when none.
    public var goalMinutes: Double?

    public init(today: String, usualWPM: Double?, todayFinishedSeconds: Double, goalMinutes: Double?) {
        self.today = today
        self.usualWPM = usualWPM
        self.todayFinishedSeconds = todayFinishedSeconds
        self.goalMinutes = goalMinutes
    }
}

public struct ReaderStatsInput: Sendable, Equatable {
    public var live: LiveSessionStats?
    public var baseline: ReaderStatsBaseline?
    public var timeLeft: TimeLeft?
    /// Same progression the scrubber shows (0…1); nil when unknown.
    public var bookProgression: Double?
    /// Scroll mode has no pages.
    public var isScrollMode: Bool

    public init(live: LiveSessionStats?, baseline: ReaderStatsBaseline?, timeLeft: TimeLeft?,
                bookProgression: Double?, isScrollMode: Bool) {
        self.live = live
        self.baseline = baseline
        self.timeLeft = timeLeft
        self.bookProgression = bookProgression
        self.isScrollMode = isScrollMode
    }
}

public struct ReaderStatValue: Sendable, Equatable, Identifiable {
    public var stat: ReaderStat
    public var text: String
    public var id: ReaderStat { stat }

    public init(stat: ReaderStat, text: String) {
        self.stat = stat
        self.text = text
    }
}

/// Turns live session numbers and baselines into display strings (reader-stats design).
public enum ReaderStatsCalculator {
    public enum Style: Sendable { case full, compact }

    /// Speed stats show "—" until the session has this much pace time and these many words.
    public static let minPaceSeconds: Double = 120
    public static let minPaceWords = 150

    /// The display text for `stat`, or nil when it doesn't apply and should be left out.
    public static func text(for stat: ReaderStat, input: ReaderStatsInput, style: Style = .full) -> String? {
        let full = style == .full
        let live = input.live
        switch stat {
        case .chapterTimeLeft:
            guard let m = input.timeLeft?.chapterMinutes else { return nil }
            return full ? "\(minutes(m)) left in chapter" : "\(minutes(m)) left"
        case .bookTimeLeft:
            guard let m = input.timeLeft?.bookMinutes else { return nil }
            return full ? "\(minutes(m)) left in book" : "\(minutes(m)) in book"
        case .bookPercent:
            guard let p = input.bookProgression else { return nil }
            return "\(Int((p * 100).rounded()))%"
        case .sessionTime:
            guard let live else { return nil }
            let total = Int(max(0, live.elapsedActiveSeconds).rounded(.down))
            let h = total / 3600, m = total % 3600 / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        case .sessionWPM:
            guard let live else { return nil }
            guard let wpm = rawWPM(live) else { return "\u{2014} wpm" }
            return "\(Int((wpm / 5).rounded()) * 5) wpm"
        case .wpmVsUsual:
            guard let live, let usual = input.baseline?.usualWPM, usual > 0, let wpm = rawWPM(live) else {
                return nil
            }
            let percent = (wpm / usual - 1) * 100
            if abs(percent) < 0.5 { return full ? "same as usual" : "\u{00B1}0%" }
            let delta = Int(percent.rounded())
            let signed = delta > 0 ? "+\(delta)%" : "\u{2212}\(-delta)%"
            return full ? "\(signed) vs usual" : signed
        case .sessionWords:
            guard let live else { return nil }
            return live.wordsRead == 1 ? "1 word" : "\(grouped(live.wordsRead)) words"
        case .sessionPages:
            guard let live, !input.isScrollMode else { return nil }
            return live.pageTurns == 1 ? "1 page" : "\(grouped(live.pageTurns)) pages"
        case .pagesPerMinute:
            guard let live, !input.isScrollMode else { return nil }
            guard !isGated(live) else { return "\u{2014} pages/min" }
            let rate = Double(live.pageTurns) / (live.paceActiveSeconds / 60)
            return String(format: "%.1f pages/min", locale: Locale(identifier: "en_US"), rate)
        case .todayVsGoal:
            guard let baseline = input.baseline else { return nil }
            var seconds = baseline.todayFinishedSeconds
            if let live, live.localDate == baseline.today { seconds += live.elapsedActiveSeconds }
            let done = Int((seconds / 60).rounded(.down))
            guard let goal = baseline.goalMinutes else { return full ? "\(done) min today" : "\(done) min" }
            let target = Int(goal.rounded())
            return full ? "\(done) / \(target) min today" : "\(done)/\(target) min"
        }
    }

    private static func isGated(_ live: LiveSessionStats) -> Bool {
        live.paceActiveSeconds < minPaceSeconds || live.wordsRead < minPaceWords
    }

    /// Unrounded words per minute from the pace clock; nil while gated.
    private static func rawWPM(_ live: LiveSessionStats) -> Double? {
        guard !isGated(live) else { return nil }
        return Double(live.wordsRead) / (live.paceActiveSeconds / 60)
    }

    private static func grouped(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// "45 min", "1 h 5 m", "1 h", "<1 min" (same as the app's `ReadingTimeFormat.minutes`).
    private static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if minutes > 0, total == 0 { return "<1 min" }
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// `stats` in order, leaving out the ones with no value.
    public static func values(_ stats: [ReaderStat], input: ReaderStatsInput, style: Style = .full)
        -> [ReaderStatValue] {
        stats.compactMap { stat in text(for: stat, input: input, style: style).map { ReaderStatValue(stat: stat, text: $0) } }
    }
}
