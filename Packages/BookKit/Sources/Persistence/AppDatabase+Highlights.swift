import Foundation
import GRDB

// Highlights, tags and bookmarks (SPEC §5.2, §7). Each write is one transaction.
// M3 scaffold: Agent A replaces the bodies.
extension AppDatabase {
    /// Inserts a highlight: new UUID, anchor_status 'exact', last_anchored_at = created_at =
    /// updated_at = now. Returns the stored row.
    @discardableResult
    public func saveHighlight(_ new: NewHighlight, now: Date = Date()) async throws -> HighlightRecord {
        fatalError("M3 scaffold")
    }

    /// Changes only the non-nil fields, bumps updated_at. No-op on a deleted or missing row.
    public func updateHighlight(id: String, color: HighlightColor? = nil, style: HighlightStyle? = nil,
                                note: String? = nil, now: Date = Date()) async throws {
        fatalError("M3 scaffold")
    }

    /// Soft-deletes the highlight and its bridge rows.
    public func softDeleteHighlight(id: String, now: Date = Date()) async throws {
        fatalError("M3 scaffold")
    }

    /// Tags a highlight. `name` is trimmed; empty returns nil. Reuses a non-deleted tag whose name
    /// matches case-insensitively, else inserts one. Adding a pair that's already linked (and not
    /// deleted) changes nothing. Returns the tag.
    @discardableResult
    public func addTag(name: String, toHighlight highlightID: String, now: Date = Date()) async throws -> TagRecord? {
        fatalError("M3 scaffold")
    }

    /// Soft-deletes the bridge row(s) linking the tag to the highlight. The tag itself stays.
    public func removeTag(tagID: String, fromHighlight highlightID: String, now: Date = Date()) async throws {
        fatalError("M3 scaffold")
    }

    @discardableResult
    public func addBookmark(_ new: NewBookmark, now: Date = Date()) async throws -> BookmarkRecord {
        fatalError("M3 scaffold")
    }

    public func softDeleteBookmark(id: String, now: Date = Date()) async throws {
        fatalError("M3 scaffold")
    }

    /// `app_setting[last_highlight_color]`, default yellow.
    public func lastHighlightColor() async throws -> HighlightColor {
        fatalError("M3 scaffold")
    }

    public func setLastHighlightColor(_ color: HighlightColor, now: Date = Date()) async throws {
        fatalError("M3 scaffold")
    }
}

/// Reads for `@Query` / `ValueObservation`. All exclude soft-deleted rows.
public enum HighlightRequests {
    /// A book's highlights in reading order (total_progression, then created_at).
    public static func highlights(bookID: String) -> QueryInterfaceRequest<HighlightRecord> {
        HighlightRecord
            .filter(HighlightRecord.Columns.bookID == bookID)
            .filter(HighlightRecord.Columns.deletedAt == nil)
            .order(HighlightRecord.Columns.totalProgression.asc, HighlightRecord.Columns.createdAt.asc)
    }

    public static func highlight(id: String) -> QueryInterfaceRequest<HighlightRecord> {
        HighlightRecord
            .filter(HighlightRecord.Columns.id == id)
            .filter(HighlightRecord.Columns.deletedAt == nil)
    }
}

public enum TagRequests {
    /// Tags linked to a highlight through non-deleted bridge rows, by name (case-insensitive),
    /// each tag once.
    public static func tags(forHighlightID highlightID: String) -> SQLRequest<TagRecord> {
        fatalError("M3 scaffold")
    }

    /// All non-deleted tags, by name (case-insensitive).
    public static func all() -> QueryInterfaceRequest<TagRecord> {
        TagRecord
            .filter(TagRecord.Columns.deletedAt == nil)
            .order(TagRecord.Columns.name.collating(.localizedCaseInsensitiveCompare))
    }
}

public enum BookmarkRequests {
    public static func bookmarks(bookID: String) -> QueryInterfaceRequest<BookmarkRecord> {
        BookmarkRecord
            .filter(BookmarkRecord.Columns.bookID == bookID)
            .filter(BookmarkRecord.Columns.deletedAt == nil)
            .order(BookmarkRecord.Columns.totalProgression.asc, BookmarkRecord.Columns.createdAt.asc)
    }
}
