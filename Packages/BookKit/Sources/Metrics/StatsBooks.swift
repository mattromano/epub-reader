import Foundation
import GRDB
import Persistence

// Stats tab: the Year in reading and Books detail screens, and the per-book stats page
// (stats-tab design).

public struct BookSummary: Sendable, Equatable, Hashable, Identifiable {
    public var bookID: String
    public var title: String
    public var authors: String
    public var status: String
    public var activeMinutes: Double
    public var wpm: Double?
    public var pctComplete: Double?
    public var lastReadDate: String?
    public var id: String { bookID }

    public init(bookID: String, title: String, authors: String, status: String, activeMinutes: Double,
                wpm: Double?, pctComplete: Double?, lastReadDate: String?) {
        self.bookID = bookID
        self.title = title
        self.authors = authors
        self.status = status
        self.activeMinutes = activeMinutes
        self.wpm = wpm
        self.pctComplete = pctComplete
        self.lastReadDate = lastReadDate
    }
}

/// Reading time and speed in one chapter, from counted page-turn/scroll location events.
public struct ChapterPace: Sendable, Equatable, Hashable, Identifiable {
    public var chapterID: String
    public var title: String?
    public var spineIndex: Int
    public var minutes: Double
    public var wordsRead: Int
    /// nil under 1 minute.
    public var wpm: Double?
    public var id: String { chapterID }

    public init(chapterID: String, title: String?, spineIndex: Int, minutes: Double, wordsRead: Int, wpm: Double?) {
        self.chapterID = chapterID
        self.title = title
        self.spineIndex = spineIndex
        self.minutes = minutes
        self.wordsRead = wordsRead
        self.wpm = wpm
    }
}

extension MetricsQueries {
    /// Per-event time cap for chapter pace (the tracker's idle threshold).
    public static let chapterPaceGapCapSeconds = 180.0
    /// Days of recent reading the projected finish date is based on.
    public static let projectionWindowDays = 14

    /// Minutes read on each day of `year` that has reading, oldest first.
    public static func calendarDays(_ db: Database, year: Int) throws -> [(localDate: String, minutes: Double)] {
        []  // TODO(Task C)
    }

    /// Minutes read per month of `year`, months 1…12 all present (0 when none).
    public static func minutesByMonth(_ db: Database, year: Int) throws -> [(month: Int, minutes: Double)] {
        []  // TODO(Task C)
    }

    /// Books with at least one session, most recently read first.
    public static func bookSummaries(_ db: Database) throws -> [BookSummary] {
        []  // TODO(Task C)
    }

    /// Chapters of `bookID` with counted reading, in spine order.
    public static func chapterPace(_ db: Database, bookID: String) throws -> [ChapterPace] {
        []  // TODO(Task C)
    }

    /// Reading day the book would be finished at the last `projectionWindowDays` days' rate on it
    /// (words read on the book in that window ÷ window days); nil when not indexed, finished, or
    /// no reading on it in the window.
    public static func projectedFinish(_ db: Database, bookID: String, today: String) throws -> String? {
        nil  // TODO(Task C)
    }

    /// Highlights per 10,000 words read on the book; nil with no words read.
    public static func highlightDensity(_ db: Database, bookID: String) throws -> Double? {
        nil  // TODO(Task C)
    }
}
