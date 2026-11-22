import Foundation
import GRDB
import Tracking

/// One row of `fact_location_event` (SPEC §5.2). Local, rebuildable; no FK to the session.
public struct LocationEventRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fact_location_event"

    public var id: String
    public var sessionID: String?
    public var bookID: String?
    public var occurredAt: String?
    public var eventType: String?
    public var chapterID: String?
    public var progression: Double?
    public var totalProgression: Double?
    public var wordIdx: Int?
    public var wordsDelta: Int?
    public var secondsSincePrev: Double?
    public var isCounted: Bool
    public var locatorJSON: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "event_id"
        case sessionID = "session_id"
        case bookID = "book_id"
        case occurredAt = "occurred_at"
        case eventType = "event_type"
        case chapterID = "chapter_id"
        case progression
        case totalProgression = "total_progression"
        case wordIdx = "word_idx"
        case wordsDelta = "words_delta"
        case secondsSincePrev = "seconds_since_prev"
        case isCounted = "is_counted"
        case locatorJSON = "locator_json"
    }

    public typealias Columns = CodingKeys

    public init(_ row: LocationEventRow) {
        id = row.eventID
        sessionID = row.sessionID
        bookID = row.bookID
        occurredAt = Timestamp.string(from: row.occurredAt)
        eventType = row.eventType.rawValue
        chapterID = row.chapterID
        progression = row.progression
        totalProgression = row.totalProgression
        wordIdx = row.wordIdx
        wordsDelta = row.wordsDelta
        secondsSincePrev = row.secondsSincePrev
        isCounted = row.isCounted
        locatorJSON = row.locatorJSON
    }
}

/// One row of `session_draft` (SPEC §5.2). Local; at most one per in-progress session.
public struct SessionDraftRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "session_draft"

    public var id: String
    public var bookID: String?
    public var startedAt: String?
    public var lastCheckpointAt: String?
    public var stateJSON: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "session_id"
        case bookID = "book_id"
        case startedAt = "started_at"
        case lastCheckpointAt = "last_checkpoint_at"
        case stateJSON = "state_json"
    }

    public typealias Columns = CodingKeys

    public init(_ draft: SessionDraft) {
        id = draft.sessionID
        bookID = draft.bookID
        startedAt = Timestamp.string(from: draft.startedAt)
        lastCheckpointAt = Timestamp.string(from: draft.lastCheckpointAt)
        stateJSON = draft.stateJSON
    }

    /// Back to the tracker's value type; nil if a timestamp or the state is missing.
    public var draft: SessionDraft? {
        guard let startedAt, let started = Timestamp.date(from: startedAt),
              let lastCheckpointAt, let last = Timestamp.date(from: lastCheckpointAt),
              let stateJSON else { return nil }
        return SessionDraft(sessionID: id, bookID: bookID ?? "", startedAt: started,
                            lastCheckpointAt: last, stateJSON: stateJSON)
    }
}

/// One row of `dim_device` (SPEC §5.2). Synced table: UUID PK, soft delete only.
public struct DeviceRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dim_device"

    public var id: String
    public var name: String?
    public var model: String?
    public var firstSeenAt: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "device_id"
        case name
        case model
        case firstSeenAt = "first_seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}
