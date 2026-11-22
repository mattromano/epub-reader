import Foundation
import GRDB
import Tracking

/// One row of `fact_reading_session` (SPEC §5.2). Synced table: UUID PK, soft delete only.
/// The field list is the contract with the app and Metrics.
public struct SessionRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fact_reading_session"

    public var id: String
    public var bookID: String?
    public var deviceID: String?
    public var startedAt: String?
    public var endedAt: String?
    public var localDate: String?
    public var localStartHour: Int?
    public var tzOffsetMinutes: Int?
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
    public var readingMode: String?
    public var fontSize: Double?
    public var endReason: String?
    public var isPaceEligible: Bool
    public var isUserEdited: Bool
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "session_id"
        case bookID = "book_id"
        case deviceID = "device_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case localDate = "local_date"
        case localStartHour = "local_start_hour"
        case tzOffsetMinutes = "tz_offset_minutes"
        case wallSeconds = "wall_seconds"
        case activeSeconds = "active_seconds"
        case startWordIdx = "start_word_idx"
        case endWordIdx = "end_word_idx"
        case wordsRead = "words_read"
        case startTotalProgression = "start_total_progression"
        case endTotalProgression = "end_total_progression"
        case startLocatorJSON = "start_locator_json"
        case endLocatorJSON = "end_locator_json"
        case pageTurns = "page_turns"
        case jumpCount = "jump_count"
        case readingMode = "reading_mode"
        case fontSize = "font_size"
        case endReason = "end_reason"
        case isPaceEligible = "is_pace_eligible"
        case isUserEdited = "is_user_edited"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    /// Session WPM (SPEC §6.3): words_read / active minutes; nil if no active time.
    public var wordsPerMinute: Double? {
        activeSeconds > 0 ? Double(wordsRead) / (activeSeconds / 60) : nil
    }
}

extension SessionRecord {
    /// Maps a finished tracker row; created_at = updated_at = `now`.
    public init(_ row: SessionRow, now: String) {
        id = row.sessionID
        bookID = row.bookID
        deviceID = row.deviceID
        startedAt = Timestamp.string(from: row.startedAt)
        endedAt = Timestamp.string(from: row.endedAt)
        localDate = row.localDate
        localStartHour = row.localStartHour
        tzOffsetMinutes = row.tzOffsetMinutes
        wallSeconds = row.wallSeconds
        activeSeconds = row.activeSeconds
        startWordIdx = row.startWordIdx
        endWordIdx = row.endWordIdx
        wordsRead = row.wordsRead
        startTotalProgression = row.startTotalProgression
        endTotalProgression = row.endTotalProgression
        startLocatorJSON = row.startLocatorJSON
        endLocatorJSON = row.endLocatorJSON
        pageTurns = row.pageTurns
        jumpCount = row.jumpCount
        readingMode = row.readingMode
        fontSize = row.fontSize
        endReason = row.endReason.rawValue
        isPaceEligible = row.isPaceEligible
        isUserEdited = false
        createdAt = now
        updatedAt = now
        deletedAt = nil
    }
}

public enum SessionRequests {
    /// Non-deleted sessions for a book, newest first.
    public static func sessions(bookID: String) -> QueryInterfaceRequest<SessionRecord> {
        SessionRecord
            .filter(SessionRecord.Columns.bookID == bookID)
            .filter(SessionRecord.Columns.deletedAt == nil)
            .order(SessionRecord.Columns.startedAt.desc)
    }
}
