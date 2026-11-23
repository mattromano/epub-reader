import Foundation
import GRDB

/// The goal metrics stored in `dim_goal.metric` (SPEC §5.2).
public enum GoalMetric: String, Codable, Sendable, CaseIterable {
    case dailyMinutes = "daily_minutes"
    case dailyWords = "daily_words"
    case yearlyBooks = "yearly_books"
}

/// One row of `dim_goal` (SPEC §5.2). SCD type 2: `[valid_from, valid_to)` in reading-day
/// `local_date`s, `valid_to` nil = current. Synced table: UUID PK, soft delete only.
public struct GoalRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dim_goal"

    public var id: String
    public var metric: String?
    public var target: Double?
    public var validFrom: String?
    public var validTo: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public init(id: String, metric: String?, target: Double?, validFrom: String?, validTo: String?,
                createdAt: String?, updatedAt: String?, deletedAt: String?) {
        self.id = id
        self.metric = metric
        self.target = target
        self.validFrom = validFrom
        self.validTo = validTo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "goal_id"
        case metric
        case target
        case validFrom = "valid_from"
        case validTo = "valid_to"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public var goalMetric: GoalMetric? { metric.flatMap(GoalMetric.init(rawValue:)) }
}

public enum GoalRequests {
    /// The current (open-ended, non-deleted) row for `metric`; the latest valid_from wins if sync
    /// delivered overlapping rows.
    public static func current(_ metric: GoalMetric) -> QueryInterfaceRequest<GoalRecord> {
        GoalRecord
            .filter(GoalRecord.Columns.metric == metric.rawValue)
            .filter(GoalRecord.Columns.validTo == nil)
            .filter(GoalRecord.Columns.deletedAt == nil)
            .order(GoalRecord.Columns.validFrom.desc, GoalRecord.Columns.updatedAt.desc)
            .limit(1)
    }

    /// Non-deleted rows for `metric`, oldest first (the goal history).
    public static func history(_ metric: GoalMetric) -> QueryInterfaceRequest<GoalRecord> {
        GoalRecord
            .filter(GoalRecord.Columns.metric == metric.rawValue)
            .filter(GoalRecord.Columns.deletedAt == nil)
            .order(GoalRecord.Columns.validFrom.asc)
    }
}
