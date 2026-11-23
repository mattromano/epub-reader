import Foundation
import GRDB

/// How the Quotes list is ordered.
public enum QuoteSort: String, Sendable, CaseIterable {
    /// Newest highlight first (flat by date).
    case recent
    /// Book title (case-insensitive), then reading order within the book (grouped by book).
    case book
}

/// Quotes view filters (SPEC §3): FTS text plus book, color and tag chips. Empty means "any".
public struct QuoteFilter: Sendable, Equatable, Hashable {
    public var search: String
    public var bookID: String?
    public var colors: Set<HighlightColor>
    public var tagID: String?
    public var sort: QuoteSort

    public init(search: String = "", bookID: String? = nil, colors: Set<HighlightColor> = [],
                tagID: String? = nil, sort: QuoteSort = .recent) {
        self.search = search
        self.bookID = bookID
        self.colors = colors
        self.tagID = tagID
        self.sort = sort
    }
}

/// One Quotes card: the highlight with its book and tag names.
public struct QuoteItem: Sendable, Equatable, Identifiable, FetchableRecord {
    public var highlight: HighlightRecord
    public var bookTitle: String
    public var bookAuthors: String
    /// Tag names, sorted case-insensitively.
    public var tags: [String]

    public var id: String { highlight.id }
    public var isOrphaned: Bool { highlight.anchorStatus == AnchorStatus.orphaned.rawValue }

    public init(highlight: HighlightRecord, bookTitle: String, bookAuthors: String, tags: [String]) {
        self.highlight = highlight
        self.bookTitle = bookTitle
        self.bookAuthors = bookAuthors
        self.tags = tags
    }

    public init(row: Row) throws {
        highlight = try HighlightRecord(row: row)
        bookTitle = row["book_title"] ?? ""
        bookAuthors = row["book_authors"] ?? ""
        let joined: String = row["tag_names"] ?? ""
        tags = joined.isEmpty ? [] : joined.components(separatedBy: QuoteRequests.tagSeparator)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// `fact_highlight.anchor_status` (SPEC §7).
public enum AnchorStatus: String, Sendable {
    case exact, fuzzy, orphaned
}

public enum FTSQuery {
    /// An FTS5 MATCH pattern for what the user typed: every word must match, each as a prefix
    /// (`"stor"*` finds "stone" and "story"). Quotes and FTS operators in the input are treated
    /// as plain text. nil when there's nothing to search for.
    public static func pattern(from input: String) -> String? {
        let tokens = input
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

public enum QuoteRequests {
    /// Separates tag names in the `tag_names` column (Unit Separator; can't be typed in a tag).
    static let tagSeparator = "\u{1F}"

    /// Non-deleted highlights of non-deleted books matching `filter`, with book title/authors and
    /// tag names (non-deleted bridge rows and tags only).
    public static func quotes(_ filter: QuoteFilter) -> SQLRequest<QuoteItem> {
        let pattern = FTSQuery.pattern(from: filter.search)
        let colorsJSON: String? = filter.colors.isEmpty ? nil : jsonArray(filter.colors.map(\.rawValue).sorted())

        let matchCTE = pattern == nil ? "" : """
            matched AS (
                SELECT highlight_id
                FROM fts_highlight
                WHERE fts_highlight MATCH :pattern
            ),

            """
        let matchFilter = pattern == nil ? "" : "AND h.highlight_id IN (SELECT highlight_id FROM matched)"
        let order = switch filter.sort {
        case .recent: "h.created_at DESC, h.highlight_id"
        case .book: "b.title COLLATE NOCASE, h.book_id, h.total_progression, h.created_at"
        }

        let sql = """
            WITH \(matchCTE)tagged AS (
                SELECT bt.highlight_id, t.tag_id, t.name
                FROM bridge_highlight_tag AS bt
                JOIN dim_tag AS t ON t.tag_id = bt.tag_id
                WHERE bt.deleted_at IS NULL AND t.deleted_at IS NULL
            ),
            tag_list AS (
                SELECT highlight_id, group_concat(name, :separator) AS tag_names
                FROM (SELECT DISTINCT highlight_id, tag_id, name FROM tagged)
                GROUP BY highlight_id
            )
            SELECT h.*, b.title AS book_title, b.authors AS book_authors, tl.tag_names
            FROM fact_highlight AS h
            JOIN dim_book AS b ON b.book_id = h.book_id
            LEFT JOIN tag_list AS tl ON tl.highlight_id = h.highlight_id
            WHERE h.deleted_at IS NULL
              AND b.deleted_at IS NULL
              \(matchFilter)
              AND (:book_id IS NULL OR h.book_id = :book_id)
              AND (:colors IS NULL OR (CASE WHEN h.color IN (SELECT value FROM json_each(:known_colors)) THEN h.color
                                            ELSE 'yellow' END) IN (SELECT value FROM json_each(:colors)))
              AND (:tag_id IS NULL OR h.highlight_id IN (SELECT highlight_id FROM tagged WHERE tag_id = :tag_id))
            ORDER BY \(order)
            """
        var arguments: StatementArguments = [
            "separator": tagSeparator, "book_id": filter.bookID, "colors": colorsJSON, "tag_id": filter.tagID,
            "known_colors": knownColorsJSON,
        ]
        if let pattern { arguments += ["pattern": pattern] }
        return SQLRequest<QuoteItem>(sql: sql, arguments: arguments)
    }

    /// Every `HighlightColor`. A NULL or unknown stored color renders as yellow
    /// (`HighlightRecord.highlightColor`), so the color filter treats it as yellow too.
    static let knownColorsJSON = jsonArray(HighlightColor.allCases.map(\.rawValue))

    private static func jsonArray(_ values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Non-deleted books that have at least one non-deleted highlight, by title (filter chip).
    public static func booksWithHighlights() -> SQLRequest<BookRecord> {
        SQLRequest<BookRecord>(sql: """
            WITH highlighted AS (
                SELECT DISTINCT book_id
                FROM fact_highlight
                WHERE deleted_at IS NULL
            )
            SELECT b.*
            FROM dim_book AS b
            JOIN highlighted AS hb ON hb.book_id = b.book_id
            WHERE b.deleted_at IS NULL
            ORDER BY b.title COLLATE NOCASE
            """)
    }
}
