import Foundation
import GRDB

// Highlights, tags and bookmarks (SPEC §5.2, §7). Each write is one transaction.
extension AppDatabase {
    /// Inserts a highlight: new UUID, anchor_status 'exact', last_anchored_at = created_at =
    /// updated_at = now. Returns the stored row.
    @discardableResult
    public func saveHighlight(_ new: NewHighlight, now: Date = Date()) async throws -> HighlightRecord {
        let nowString = Timestamp.string(from: now)
        let record = HighlightRecord(
            id: UUID().uuidString, bookID: new.bookID, chapterID: new.chapterID, spineHref: new.spineHref,
            chapterTitle: new.chapterTitle, quoteExact: new.quoteExact, quotePrefix: new.quotePrefix,
            quoteSuffix: new.quoteSuffix, charStart: new.charStart, charEnd: new.charEnd,
            wordIdx: new.wordIdx, wordCount: new.wordCount, progression: new.progression,
            totalProgression: new.totalProgression, position: new.position, cssSelector: new.cssSelector,
            partialCFI: new.partialCFI, domRangeJSON: new.domRangeJSON, locatorJSON: new.locatorJSON,
            readiumVersion: new.readiumVersion, chapterTextHash: new.chapterTextHash,
            anchorStatus: "exact", anchorScore: nil, lastAnchoredAt: nowString,
            color: new.color.rawValue, note: new.note, style: new.style.rawValue, exportReadwiseAt: nil,
            createdAt: nowString, updatedAt: nowString, deletedAt: nil)
        try await writer.write { db in
            try record.insert(db)
        }
        return record
    }

    /// Changes only the non-nil fields, bumps updated_at. No-op on a deleted or missing row.
    public func updateHighlight(id: String, color: HighlightColor? = nil, style: HighlightStyle? = nil,
                                note: String? = nil, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE fact_highlight
                    SET color = COALESCE(:color, color),
                        style = COALESCE(:style, style),
                        note = COALESCE(:note, note),
                        updated_at = :now
                    WHERE highlight_id = :id AND deleted_at IS NULL
                    """,
                arguments: ["color": color?.rawValue, "style": style?.rawValue, "note": note,
                            "now": nowString, "id": id])
        }
    }

    /// Soft-deletes the highlight and its bridge rows.
    public func softDeleteHighlight(id: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE fact_highlight
                    SET deleted_at = :now, updated_at = :now
                    WHERE highlight_id = :id AND deleted_at IS NULL;
                    UPDATE bridge_highlight_tag
                    SET deleted_at = :now, updated_at = :now
                    WHERE highlight_id = :id AND deleted_at IS NULL;
                    """,
                arguments: ["now": nowString, "id": id])
        }
    }

    /// Tags a highlight. `name` is trimmed; empty returns nil. Reuses a non-deleted tag whose name
    /// matches case-insensitively, else inserts one. Adding a pair that's already linked (and not
    /// deleted) changes nothing. Returns the tag.
    @discardableResult
    public func addTag(name: String, toHighlight highlightID: String, now: Date = Date()) async throws -> TagRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let nowString = Timestamp.string(from: now)
        return try await writer.write { db in
            guard try HighlightRequests.highlight(id: highlightID).fetchCount(db) > 0 else { return nil }

            // Case-insensitive dedupe in Swift: SQLite's NOCASE only folds ASCII.
            let existing = try TagRecord
                .filter(TagRecord.Columns.deletedAt == nil)
                .order(TagRecord.Columns.createdAt.asc)
                .fetchAll(db)
                .first { ($0.name ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }
            let tag: TagRecord
            if let existing {
                tag = existing
            } else {
                tag = TagRecord(id: UUID().uuidString, name: trimmed, color: nil,
                                createdAt: nowString, updatedAt: nowString, deletedAt: nil)
                try tag.insert(db)
            }

            let linked = try HighlightTagRecord
                .filter(HighlightTagRecord.Columns.highlightID == highlightID)
                .filter(HighlightTagRecord.Columns.tagID == tag.id)
                .filter(HighlightTagRecord.Columns.deletedAt == nil)
                .fetchCount(db) > 0
            if !linked {
                try HighlightTagRecord(id: UUID().uuidString, highlightID: highlightID, tagID: tag.id,
                                       createdAt: nowString, updatedAt: nowString, deletedAt: nil).insert(db)
            }
            return tag
        }
    }

    /// Soft-deletes the bridge row(s) linking the tag to the highlight. The tag itself stays.
    public func removeTag(tagID: String, fromHighlight highlightID: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE bridge_highlight_tag
                    SET deleted_at = :now, updated_at = :now
                    WHERE highlight_id = :highlight AND tag_id = :tag AND deleted_at IS NULL
                    """,
                arguments: ["now": nowString, "highlight": highlightID, "tag": tagID])
        }
    }

    @discardableResult
    public func addBookmark(_ new: NewBookmark, now: Date = Date()) async throws -> BookmarkRecord {
        let nowString = Timestamp.string(from: now)
        let record = BookmarkRecord(
            id: UUID().uuidString, bookID: new.bookID, spineHref: new.spineHref, progression: new.progression,
            locatorJSON: new.locatorJSON, totalProgression: new.totalProgression, label: new.label,
            createdAt: nowString, updatedAt: nowString, deletedAt: nil)
        try await writer.write { db in
            try record.insert(db)
        }
        return record
    }

    public func softDeleteBookmark(id: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE fact_bookmark
                    SET deleted_at = ?, updated_at = ?
                    WHERE bookmark_id = ? AND deleted_at IS NULL
                    """,
                arguments: [nowString, nowString, id])
        }
    }

    /// `app_setting[last_highlight_color]`, default yellow.
    public func lastHighlightColor() async throws -> HighlightColor {
        guard let json = try await settingJSON(forKey: Self.lastHighlightColorKey),
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(String.self, from: data) else {
            return .yellow
        }
        return HighlightColor(rawValue: raw) ?? .yellow
    }

    public func setLastHighlightColor(_ color: HighlightColor, now: Date = Date()) async throws {
        let data = try JSONEncoder().encode(color.rawValue)
        try await setSettingJSON(String(decoding: data, as: UTF8.self), forKey: Self.lastHighlightColorKey, now: now)
    }

    private static let lastHighlightColorKey = "last_highlight_color"
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
        let collation = DatabaseCollation.localizedCaseInsensitiveCompare.name
        return SQLRequest<TagRecord>(
            sql: """
                WITH linked_tag AS (
                    SELECT DISTINCT tag_id
                    FROM bridge_highlight_tag
                    WHERE highlight_id = ? AND deleted_at IS NULL
                )
                SELECT t.tag_id, t.name, t.color, t.created_at, t.updated_at, t.deleted_at
                FROM dim_tag AS t
                JOIN linked_tag AS l ON l.tag_id = t.tag_id
                WHERE t.deleted_at IS NULL
                ORDER BY t.name COLLATE \(collation), t.created_at
                """,
            arguments: [highlightID])
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
