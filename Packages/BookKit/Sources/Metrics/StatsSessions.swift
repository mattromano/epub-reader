import Foundation
import GRDB
import Persistence

// Stats tab: the Sessions and Personal bests detail screens (stats-tab design).

public struct SessionLogEntry: Sendable, Equatable, Hashable, Identifiable {
    public var sessionID: String
    public var bookID: String?
    /// "" when the book is gone.
    public var bookTitle: String
    /// UTC ISO-8601, as stored.
    public var startedAt: String
    public var localDate: String
    public var activeSeconds: Double
    public var wordsRead: Int
    public var pageTurns: Int
    public var readingMode: String?
    /// words / active minutes for pace-eligible sessions with words; else nil.
    public var wpm: Double?
    public var id: String { sessionID }

    public init(sessionID: String, bookID: String?, bookTitle: String, startedAt: String, localDate: String,
                activeSeconds: Double, wordsRead: Int, pageTurns: Int, readingMode: String?, wpm: Double?) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.startedAt = startedAt
        self.localDate = localDate
        self.activeSeconds = activeSeconds
        self.wordsRead = wordsRead
        self.pageTurns = pageTurns
        self.readingMode = readingMode
        self.wpm = wpm
    }
}

/// One bar of the session-length chart: sessions whose active minutes fall in
/// `[lowerMinutes, next bucket's lowerMinutes)`.
public struct SessionLengthBucket: Sendable, Equatable, Hashable, Identifiable {
    /// One of `MetricsQueries.sessionLengthBuckets`.
    public var lowerMinutes: Int
    public var count: Int
    public var id: Int { lowerMinutes }

    public init(lowerMinutes: Int, count: Int) {
        self.lowerMinutes = lowerMinutes
        self.count = count
    }
}

public enum PersonalRecordKind: String, CaseIterable, Sendable {
    case longestSession = "longest_session"
    /// Highest WPM among pace-eligible sessions with ≥ 10 active minutes.
    case fastestSession = "fastest_session"
    case mostMinutesInDay = "most_minutes_in_day"
    case mostWordsInDay = "most_words_in_day"
    case mostPagesInSession = "most_pages_in_session"
    case longestStreak = "longest_streak"
}

public struct PersonalRecord: Sendable, Equatable, Hashable, Identifiable {
    public var kind: PersonalRecordKind
    /// Seconds (longestSession), WPM (fastestSession), minutes (mostMinutesInDay), words,
    /// pages, or days (longestStreak).
    public var value: Double
    /// The reading day it happened; nil for longestStreak.
    public var localDate: String?
    /// For session records; nil for day records and the streak.
    public var bookTitle: String?
    public var id: PersonalRecordKind { kind }

    public init(kind: PersonalRecordKind, value: Double, localDate: String?, bookTitle: String?) {
        self.kind = kind
        self.value = value
        self.localDate = localDate
        self.bookTitle = bookTitle
    }
}

extension MetricsQueries {
    /// Lower bounds (minutes) of the session-length buckets; the last is open-ended.
    public static let sessionLengthBuckets = [0, 5, 10, 20, 30, 45, 60]
    /// Fastest-session records only count sessions at least this long.
    public static let fastestSessionMinSeconds = 600.0

    /// Non-deleted sessions, newest `started_at` first, optionally for one book.
    public static func sessionLog(_ db: Database, bookID: String? = nil, limit: Int = 200) throws -> [SessionLogEntry] {
        []  // TODO(Task B)
    }

    /// Every bucket in `sessionLengthBuckets` order (zero counts included) for sessions in `[from, to]`.
    public static func sessionLengthHistogram(_ db: Database, from: String, to: String) throws -> [SessionLengthBucket] {
        []  // TODO(Task B)
    }

    /// One record per kind that has data, in `PersonalRecordKind.allCases` order. Ties go to
    /// the earliest. The streak uses `streaks(_:today:minMinutes:)`.
    public static func personalRecords(_ db: Database, today: String, minMinutes: Double) throws -> [PersonalRecord] {
        []  // TODO(Task B)
    }
}
