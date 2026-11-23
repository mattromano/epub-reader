import Foundation

/// Read-only view of the session in progress, for the reader's live stats (reader-stats design).
/// Display only: the finished `SessionRow` stays the source of truth.
public struct LiveSessionStats: Sendable, Equatable {
    /// Reading day the session started on.
    public var localDate: String
    /// Active seconds including the running stretch since the last activity (capped at the idle
    /// threshold; frozen while paused). Drives the session timer.
    public var elapsedActiveSeconds: Double
    /// Active seconds as of the last location event. Drives WPM and pages/min, so speed holds
    /// steady between page turns instead of sagging every second.
    public var paceActiveSeconds: Double
    public var wordsRead: Int
    public var pageTurns: Int
    public var isPaused: Bool

    public init(localDate: String, elapsedActiveSeconds: Double, paceActiveSeconds: Double,
                wordsRead: Int, pageTurns: Int, isPaused: Bool) {
        self.localDate = localDate
        self.elapsedActiveSeconds = elapsedActiveSeconds
        self.paceActiveSeconds = paceActiveSeconds
        self.wordsRead = wordsRead
        self.pageTurns = pageTurns
        self.isPaused = isPaused
    }
}

extension SessionTracker {
    /// Snapshot of the session in progress at `date`; nil when no session is in progress
    /// (idle or dormant). Pure: does not mutate the tracker.
    public func live(at date: Date) -> LiveSessionStats? {
        nil  // TODO(Task 1)
    }
}
