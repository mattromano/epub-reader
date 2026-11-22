import Foundation

/// Reading status stored in `dim_book.status`.
public enum BookStatus: String, Codable, CaseIterable, Sendable {
    case toRead = "to_read"
    case reading
    case finished
    case abandoned

    public var displayName: String {
        switch self {
        case .toRead: "To read"
        case .reading: "Reading"
        case .finished: "Finished"
        case .abandoned: "Abandoned"
        }
    }
}

extension BookRecord {
    /// Typed status; unknown raw values fall back to `.toRead`.
    public var bookStatus: BookStatus { BookStatus(rawValue: status) ?? .toRead }
}

/// Keys used in `app_setting`.
public enum AppSettingKey {
    public static let defaultPreferences = "default_preferences"
}
