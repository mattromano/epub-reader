import GRDB

public enum LibrarySort: String, CaseIterable, Sendable {
    case recent, title, author, progress

    public var displayName: String {
        switch self {
        case .recent: "Recent"
        case .title: "Title"
        case .author: "Author"
        case .progress: "Progress"
        }
    }
}

public enum LibraryRequests {
    /// Non-deleted books, ordered by last_opened_at DESC NULLS LAST, then created_at DESC.
    /// (SQLite sorts NULL lowest, so plain DESC already puts never-opened books last.)
    public static func allBooks() -> QueryInterfaceRequest<BookRecord> {
        books(sort: .recent, search: "")
    }

    /// Non-deleted books filtered by a literal, case-insensitive substring of title or authors,
    /// ordered by `sort`. Every ordering ends with book_id for a stable tie-break.
    public static func books(sort: LibrarySort, search: String) -> QueryInterfaceRequest<BookRecord> {
        typealias C = BookRecord.Columns
        var request = BookRecord.filter(C.deletedAt == nil)

        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            request = request.filter(
                sql: "(title LIKE ? ESCAPE '\\' OR authors LIKE ? ESCAPE '\\')",
                arguments: [pattern, pattern])
        }

        switch sort {
        case .recent:
            return request.order(C.lastOpenedAt.desc, C.createdAt.desc, C.id.asc)
        case .title:
            return request.order(C.title.collating(.nocase).asc, C.id.asc)
        case .author:
            return request.order(C.authors.collating(.nocase).asc,
                                 C.title.collating(.nocase).asc, C.id.asc)
        case .progress:
            return request.order(C.lastTotalProgression.desc, C.lastOpenedAt.desc, C.id.asc)
        }
    }
}
