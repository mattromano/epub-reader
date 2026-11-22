import GRDB

public enum LibraryRequests {
    /// Non-deleted books, ordered by last_opened_at DESC NULLS LAST, then created_at DESC.
    /// (SQLite sorts NULL lowest, so plain DESC already puts never-opened books last.)
    public static func allBooks() -> QueryInterfaceRequest<BookRecord> {
        BookRecord
            .filter(BookRecord.Columns.deletedAt == nil)
            .order(BookRecord.Columns.lastOpenedAt.desc, BookRecord.Columns.createdAt.desc)
    }
}
