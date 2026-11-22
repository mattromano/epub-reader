import Foundation
import GRDB

/// One row of `app_setting` (SPEC §5.2). `key` is not unique: duplicates can arrive via sync,
/// and the row with the latest `updated_at` wins.
public struct AppSettingRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "app_setting"

    public var id: String
    public var key: String
    public var valueJSON: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "setting_id"
        case key
        case valueJSON = "value_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}
