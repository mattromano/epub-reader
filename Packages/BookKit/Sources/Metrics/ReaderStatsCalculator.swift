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
        nil  // TODO(Task 2)
    }

    /// `stats` in order, leaving out the ones with no value.
    public static func values(_ stats: [ReaderStat], input: ReaderStatsInput, style: Style = .full)
        -> [ReaderStatValue] {
        stats.compactMap { stat in text(for: stat, input: input, style: style).map { ReaderStatValue(stat: stat, text: $0) } }
    }
}
