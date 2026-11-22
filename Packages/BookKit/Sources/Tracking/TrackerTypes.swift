import Foundation

// Public contract for the session tracker (SPEC §6.1–6.2). Pure values: no DB, timers or UIKit.
// Persistence maps these rows to records; the app feeds events in.

/// Thresholds and calendar settings. Loaded by the app from `app_setting`
/// (`idle_threshold_s`, `session_gap_s`, `day_start_hour`); tests set them directly.
public struct TrackerConfig: Codable, Sendable, Equatable {
    /// No location event for this long → paused (idle). SPEC default 180 s.
    public var idleThreshold: TimeInterval
    /// A pause longer than this ends the session; resuming within it continues. SPEC default 300 s.
    public var sessionGap: TimeInterval
    /// Reading-day boundary hour (local). SPEC default 4.
    public var dayStartHour: Int
    /// Time zone used for `local_date`, `local_start_hour`, `tz_offset_minutes`.
    public var timeZone: TimeZone
    /// Discard rule: sessions with less active time are dropped. SPEC 30 s.
    public var minActiveSeconds: TimeInterval
    /// Counted-event rate limit. SPEC 1500 WPM.
    public var maxWordsPerMinute: Double
    /// Floor of the per-event word cap: max(minWordCap, 5 × p95 page words). SPEC 1500.
    public var minWordCap: Int
    /// Scroll throttle: at most one scroll event per this interval… SPEC 2 s.
    public var scrollMinInterval: TimeInterval
    /// …and per this change in total progression. SPEC 0.005 (0.5%).
    public var scrollMinProgressionDelta: Double
    /// How often the app sends `.tick` / the tracker emits a checkpoint. SPEC 30 s.
    public var checkpointInterval: TimeInterval

    public init(
        idleThreshold: TimeInterval = 180,
        sessionGap: TimeInterval = 300,
        dayStartHour: Int = 4,
        timeZone: TimeZone = .current,
        minActiveSeconds: TimeInterval = 30,
        maxWordsPerMinute: Double = 1500,
        minWordCap: Int = 1500,
        scrollMinInterval: TimeInterval = 2,
        scrollMinProgressionDelta: Double = 0.005,
        checkpointInterval: TimeInterval = 30
    ) {
        self.idleThreshold = idleThreshold
        self.sessionGap = sessionGap
        self.dayStartHour = dayStartHour
        self.timeZone = timeZone
        self.minActiveSeconds = minActiveSeconds
        self.maxWordsPerMinute = maxWordsPerMinute
        self.minWordCap = minWordCap
        self.scrollMinInterval = scrollMinInterval
        self.scrollMinProgressionDelta = scrollMinProgressionDelta
        self.checkpointInterval = checkpointInterval
    }
}

/// How the reader got to a new location (classified by the app).
public enum LocationKind: String, Codable, Sendable {
    case pageTurn = "page_turn"
    case scroll
    /// TOC, search, scrubber, internal link, highlight tap, preferences change, rotation.
    case jump
}

/// One navigator location change, already mapped to BookKit values by the app.
public struct LocationSample: Codable, Sendable, Equatable {
    public var kind: LocationKind
    /// Book-level word index from `WordIndex`; nil when the book isn't indexed (or is fixed layout).
    public var wordIdx: Int?
    /// `dim_chapter.chapter_id` (`<book_id>:<spine_index>`), when known.
    public var chapterID: String?
    /// Progression within the resource (0–1).
    public var progression: Double?
    /// Progression through the whole book (0–1).
    public var totalProgression: Double?
    /// Full Readium locator JSON.
    public var locatorJSON: String?

    public init(kind: LocationKind, wordIdx: Int?, chapterID: String?, progression: Double?,
                totalProgression: Double?, locatorJSON: String?) {
        self.kind = kind
        self.wordIdx = wordIdx
        self.chapterID = chapterID
        self.progression = progression
        self.totalProgression = totalProgression
        self.locatorJSON = locatorJSON
    }
}

/// Per-book context sent with `.open`. Calendar fields (local_date etc.) are derived by the
/// tracker from `TrackerConfig`, so a new session started mid-read gets them right.
public struct SessionContext: Codable, Sendable, Equatable {
    public var bookID: String
    public var deviceID: String
    /// 'paginated' / 'scroll'.
    public var readingMode: String
    /// Font size snapshot (Readium fontSize, 1.0 = 100%).
    public var fontSize: Double?
    /// Fixed layout: time tracked, words not; sessions are never pace-eligible.
    public var isFixedLayout: Bool

    public init(bookID: String, deviceID: String, readingMode: String, fontSize: Double?, isFixedLayout: Bool) {
        self.bookID = bookID
        self.deviceID = deviceID
        self.readingMode = readingMode
        self.fontSize = fontSize
        self.isFixedLayout = isFixedLayout
    }
}

public enum TrackerEvent: Sendable, Equatable {
    /// Book opened (reader appeared). Starts a session.
    case open(SessionContext)
    /// Navigator location changed.
    case location(LocationSample)
    /// App went to background / screen locked.
    case background
    /// App came back to foreground.
    case foreground
    /// Periodic timer (every `checkpointInterval`): idle detection + checkpoint.
    case tick
    /// Reader closed.
    case close
    /// Reading mode / font changed (preferences applied). Updates the snapshot for the
    /// current session; the app also sends a `.location` with kind `.jump` for the move.
    case contextChanged(readingMode: String, fontSize: Double?)
}

/// `fact_reading_session.end_reason`.
public enum EndReason: String, Codable, Sendable {
    case closed
    case backgrounded
    case idleTimeout = "idle_timeout"
    case bookSwitched = "book_switched"
    case crashRecovered = "crash_recovered"
}

/// `fact_location_event.event_type`.
public enum LocationEventType: String, Codable, Sendable {
    case pageTurn = "page_turn"
    case scroll
    case jump
    case open
    case close
    case pause
    case resume
}

/// One `fact_location_event` row.
public struct LocationEventRow: Codable, Sendable, Equatable {
    public var eventID: String
    public var sessionID: String
    public var bookID: String
    public var occurredAt: Date
    public var eventType: LocationEventType
    public var chapterID: String?
    public var progression: Double?
    public var totalProgression: Double?
    public var wordIdx: Int?
    public var wordsDelta: Int?
    public var secondsSincePrev: Double?
    public var isCounted: Bool
    public var locatorJSON: String?

    public init(eventID: String, sessionID: String, bookID: String, occurredAt: Date,
                eventType: LocationEventType, chapterID: String?, progression: Double?,
                totalProgression: Double?, wordIdx: Int?, wordsDelta: Int?,
                secondsSincePrev: Double?, isCounted: Bool, locatorJSON: String?) {
        self.eventID = eventID
        self.sessionID = sessionID
        self.bookID = bookID
        self.occurredAt = occurredAt
        self.eventType = eventType
        self.chapterID = chapterID
        self.progression = progression
        self.totalProgression = totalProgression
        self.wordIdx = wordIdx
        self.wordsDelta = wordsDelta
        self.secondsSincePrev = secondsSincePrev
        self.isCounted = isCounted
        self.locatorJSON = locatorJSON
    }
}

/// One finished `fact_reading_session` row (written once at session end).
public struct SessionRow: Codable, Sendable, Equatable {
    public var sessionID: String
    public var bookID: String
    public var deviceID: String
    public var startedAt: Date
    public var endedAt: Date
    /// Reading-day of `startedAt` ('YYYY-MM-DD'), using `dayStartHour`.
    public var localDate: String
    public var localStartHour: Int
    public var tzOffsetMinutes: Int
    public var wallSeconds: Double
    public var activeSeconds: Double
    public var startWordIdx: Int?
    public var endWordIdx: Int?
    public var wordsRead: Int
    public var startTotalProgression: Double?
    public var endTotalProgression: Double?
    public var startLocatorJSON: String?
    public var endLocatorJSON: String?
    public var pageTurns: Int
    public var jumpCount: Int
    public var readingMode: String
    public var fontSize: Double?
    public var endReason: EndReason
    public var isPaceEligible: Bool

    public init(sessionID: String, bookID: String, deviceID: String, startedAt: Date, endedAt: Date,
                localDate: String, localStartHour: Int, tzOffsetMinutes: Int, wallSeconds: Double,
                activeSeconds: Double, startWordIdx: Int?, endWordIdx: Int?, wordsRead: Int,
                startTotalProgression: Double?, endTotalProgression: Double?,
                startLocatorJSON: String?, endLocatorJSON: String?, pageTurns: Int, jumpCount: Int,
                readingMode: String, fontSize: Double?, endReason: EndReason, isPaceEligible: Bool) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.localDate = localDate
        self.localStartHour = localStartHour
        self.tzOffsetMinutes = tzOffsetMinutes
        self.wallSeconds = wallSeconds
        self.activeSeconds = activeSeconds
        self.startWordIdx = startWordIdx
        self.endWordIdx = endWordIdx
        self.wordsRead = wordsRead
        self.startTotalProgression = startTotalProgression
        self.endTotalProgression = endTotalProgression
        self.startLocatorJSON = startLocatorJSON
        self.endLocatorJSON = endLocatorJSON
        self.pageTurns = pageTurns
        self.jumpCount = jumpCount
        self.readingMode = readingMode
        self.fontSize = fontSize
        self.endReason = endReason
        self.isPaceEligible = isPaceEligible
    }
}

/// One `session_draft` row: the in-progress session, checkpointed every `checkpointInterval`.
public struct SessionDraft: Codable, Sendable, Equatable {
    public var sessionID: String
    public var bookID: String
    public var startedAt: Date
    /// The recovered session ends here.
    public var lastCheckpointAt: Date
    /// Serialized `SessionTracker` (JSON).
    public var stateJSON: String

    public init(sessionID: String, bookID: String, startedAt: Date, lastCheckpointAt: Date, stateJSON: String) {
        self.sessionID = sessionID
        self.bookID = bookID
        self.startedAt = startedAt
        self.lastCheckpointAt = lastCheckpointAt
        self.stateJSON = stateJSON
    }
}

public enum TrackerOutput: Sendable, Equatable {
    /// Append to `fact_location_event`.
    case locationEvent(LocationEventRow)
    /// Upsert `session_draft` (skip if the session row already exists).
    case checkpoint(SessionDraft)
    /// Insert `fact_reading_session`, delete its draft.
    case sessionEnded(SessionRow)
    /// Failed the discard rule: delete its draft and location events.
    case sessionDiscarded(sessionID: String)
}

/// Time source for the app driver; tests pass dates to `handle(_:at:)` directly.
public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
