import Foundation
import GRDB

/// A highlight waiting for a Readwise push (M7), with what the request needs.
public struct ReadwisePendingHighlight: Sendable, Equatable, FetchableRecord {
    public var highlightID: String
    public var bookTitle: String
    public var bookAuthors: String
    public var quote: String
    public var note: String
    public var color: String?
    public var wordIdx: Int?
    public var createdAt: String?
    /// Tag names, sorted case-insensitively.
    public var tags: [String]
    /// The Readwise highlight id, when known (`readwise_highlight`).
    public var readwiseID: Int?
    /// True when an earlier push already sent this highlight (`export_readwise_at` is set).
    public var wasExported: Bool

    public init(highlightID: String, bookTitle: String, bookAuthors: String, quote: String, note: String,
                color: String?, wordIdx: Int?, createdAt: String?, tags: [String], readwiseID: Int?,
                wasExported: Bool) {
        self.highlightID = highlightID
        self.bookTitle = bookTitle
        self.bookAuthors = bookAuthors
        self.quote = quote
        self.note = note
        self.color = color
        self.wordIdx = wordIdx
        self.createdAt = createdAt
        self.tags = tags
        self.readwiseID = readwiseID
        self.wasExported = wasExported
    }

    public init(row: Row) throws {
        highlightID = row["highlight_id"]
        bookTitle = row["book_title"] ?? ""
        bookAuthors = row["book_authors"] ?? ""
        quote = row["quote_exact"] ?? ""
        note = row["note"] ?? ""
        color = row["color"]
        wordIdx = row["word_idx"]
        createdAt = row["created_at"]
        let joined: String = row["tag_names"] ?? ""
        tags = joined.isEmpty ? [] : QuoteItem.displayTags(joined.components(separatedBy: QuoteRequests.tagSeparator))
        readwiseID = row["readwise_highlight_id"]
        wasExported = row["was_exported"] ?? false
    }
}

/// What Settings shows for Readwise.
public struct ReadwiseStatus: Sendable, Equatable {
    public var pendingCount: Int
    /// The latest `export_readwise_at`, nil before the first push.
    public var lastPushAt: String?

    public init(pendingCount: Int, lastPushAt: String?) {
        self.pendingCount = pendingCount
        self.lastPushAt = lastPushAt
    }
}

extension AppDatabase {
    /// Live highlights of live books with a non-blank quote (Readwise requires `text`) that were
    /// never pushed, or changed (`updated_at`) since their last push. Tag changes don't bump
    /// `updated_at` and aren't pushed after the first time (inline tags only apply on create).
    static let pendingReadwiseSQL = """
        WITH tagged AS (
            SELECT DISTINCT bt.highlight_id, t.tag_id, t.name
            FROM bridge_highlight_tag AS bt
            JOIN dim_tag AS t ON t.tag_id = bt.tag_id
            WHERE bt.deleted_at IS NULL AND t.deleted_at IS NULL
        ),
        tag_list AS (
            SELECT highlight_id, group_concat(name, :separator) AS tag_names
            FROM tagged
            GROUP BY highlight_id
        ),
        pending AS (
            SELECT h.highlight_id
            FROM fact_highlight AS h
            JOIN dim_book AS b ON b.book_id = h.book_id
            WHERE h.deleted_at IS NULL
              AND b.deleted_at IS NULL
              AND trim(h.quote_exact, ' ' || char(9, 10, 13)) <> ''
              AND (h.export_readwise_at IS NULL OR h.updated_at > h.export_readwise_at)
        )
        SELECT h.highlight_id, b.title AS book_title, b.authors AS book_authors, h.quote_exact, h.note,
               h.color, h.word_idx, h.created_at, tl.tag_names, rh.readwise_highlight_id,
               h.export_readwise_at IS NOT NULL AS was_exported
        FROM pending AS p
        JOIN fact_highlight AS h ON h.highlight_id = p.highlight_id
        JOIN dim_book AS b ON b.book_id = h.book_id
        LEFT JOIN tag_list AS tl ON tl.highlight_id = h.highlight_id
        LEFT JOIN readwise_highlight AS rh ON rh.highlight_id = h.highlight_id
        ORDER BY h.created_at, h.highlight_id
        """

    public func pendingReadwiseHighlights() async throws -> [ReadwisePendingHighlight] {
        try await reader.read { db in
            try ReadwisePendingHighlight.fetchAll(
                db, sql: Self.pendingReadwiseSQL, arguments: ["separator": QuoteRequests.tagSeparator])
        }
    }

    public func readwiseStatus() async throws -> ReadwiseStatus {
        try await reader.read { db in
            let pending = try Int.fetchOne(db, sql: """
                WITH pending AS (\(Self.pendingReadwiseSQL))
                SELECT COUNT(*) FROM pending
                """, arguments: ["separator": QuoteRequests.tagSeparator]) ?? 0
            let last = try String.fetchOne(db, sql: """
                SELECT MAX(export_readwise_at) FROM fact_highlight WHERE deleted_at IS NULL
                """)
            return ReadwiseStatus(pendingCount: pending, lastPushAt: last)
        }
    }

    /// Records a successful push. Sets only `export_readwise_at` (never `updated_at`), to the
    /// push's start time, so an edit made while the push ran is still newer and goes next time.
    public func markReadwiseExported(highlightIDs: [String], at pushStart: Date) async throws {
        guard !highlightIDs.isEmpty else { return }
        let stamp = Timestamp.string(from: pushStart)
        let ids = try Self.jsonArray(highlightIDs)
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE fact_highlight
                SET export_readwise_at = :stamp
                WHERE highlight_id IN (SELECT value FROM json_each(:ids))
                """, arguments: ["stamp": stamp, "ids": ids])
        }
    }

    /// Stores Readwise ids by highlight id (upsert).
    public func setReadwiseIDs(_ ids: [String: Int], now: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let stamp = Timestamp.string(from: now)
        try await writer.write { db in
            for (highlightID, readwiseID) in ids {
                try db.execute(sql: """
                    INSERT INTO readwise_highlight (highlight_id, readwise_highlight_id, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT (highlight_id) DO UPDATE
                    SET readwise_highlight_id = excluded.readwise_highlight_id, updated_at = excluded.updated_at
                    """, arguments: [highlightID, readwiseID, stamp])
            }
        }
    }

    /// Forgets a Readwise id that no longer exists there (local-only mapping, not user data).
    public func clearReadwiseID(highlightID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM readwise_highlight WHERE highlight_id = ?", arguments: [highlightID])
        }
    }

    private static func jsonArray(_ values: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}
