import Foundation
import GRDB

/// Highlight tint (`fact_highlight.color`).
public enum HighlightColor: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple
}

/// Highlight rendering style (`fact_highlight.style`).
public enum HighlightStyle: String, Codable, Sendable, CaseIterable {
    case highlight, underline
}

/// One row of `fact_highlight` (SPEC §5.2, anchoring in §7). Synced table: UUID PK, soft delete.
/// `id` is also the Readium `Decoration.id`.
public struct HighlightRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fact_highlight"

    public var id: String
    public var bookID: String?
    public var chapterID: String?
    public var spineHref: String?
    public var chapterTitle: String?
    public var quoteExact: String
    public var quotePrefix: String?
    public var quoteSuffix: String?
    public var charStart: Int?
    public var charEnd: Int?
    public var wordIdx: Int?
    public var wordCount: Int?
    public var progression: Double?
    public var totalProgression: Double?
    public var position: Int?
    public var cssSelector: String?
    public var partialCFI: String?
    public var domRangeJSON: String?
    /// The raw Readium selection locator, unmodified (Readium re-anchors from its text).
    public var locatorJSON: String?
    public var readiumVersion: String?
    public var chapterTextHash: String?
    /// exact / fuzzy / orphaned.
    public var anchorStatus: String?
    public var anchorScore: Double?
    public var lastAnchoredAt: String?
    /// `HighlightColor` raw value; unknown values render as yellow.
    public var color: String?
    public var note: String?
    /// `HighlightStyle` raw value.
    public var style: String?
    public var exportReadwiseAt: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "highlight_id"
        case bookID = "book_id"
        case chapterID = "chapter_id"
        case spineHref = "spine_href"
        case chapterTitle = "chapter_title"
        case quoteExact = "quote_exact"
        case quotePrefix = "quote_prefix"
        case quoteSuffix = "quote_suffix"
        case charStart = "char_start"
        case charEnd = "char_end"
        case wordIdx = "word_idx"
        case wordCount = "word_count"
        case progression
        case totalProgression = "total_progression"
        case position
        case cssSelector = "css_selector"
        case partialCFI = "partial_cfi"
        case domRangeJSON = "dom_range_json"
        case locatorJSON = "locator_json"
        case readiumVersion = "readium_version"
        case chapterTextHash = "chapter_text_hash"
        case anchorStatus = "anchor_status"
        case anchorScore = "anchor_score"
        case lastAnchoredAt = "last_anchored_at"
        case color
        case note
        case style
        case exportReadwiseAt = "export_readwise_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys

    public var highlightColor: HighlightColor { color.flatMap(HighlightColor.init(rawValue:)) ?? .yellow }
    public var highlightStyle: HighlightStyle { style.flatMap(HighlightStyle.init(rawValue:)) ?? .highlight }
}

/// What the app captures for a new highlight; `saveHighlight` adds id, anchor status and timestamps.
public struct NewHighlight: Sendable, Equatable {
    public var bookID: String
    public var chapterID: String?
    public var spineHref: String?
    public var chapterTitle: String?
    public var quoteExact: String
    public var quotePrefix: String
    public var quoteSuffix: String
    public var charStart: Int?
    public var charEnd: Int?
    public var wordIdx: Int?
    public var wordCount: Int?
    public var progression: Double?
    public var totalProgression: Double?
    public var position: Int?
    public var cssSelector: String?
    public var partialCFI: String?
    public var domRangeJSON: String?
    public var locatorJSON: String
    public var readiumVersion: String?
    public var chapterTextHash: String?
    public var color: HighlightColor
    public var style: HighlightStyle
    public var note: String

    public init(bookID: String, chapterID: String? = nil, spineHref: String? = nil,
                chapterTitle: String? = nil, quoteExact: String, quotePrefix: String = "",
                quoteSuffix: String = "", charStart: Int? = nil, charEnd: Int? = nil,
                wordIdx: Int? = nil, wordCount: Int? = nil, progression: Double? = nil,
                totalProgression: Double? = nil, position: Int? = nil, cssSelector: String? = nil,
                partialCFI: String? = nil, domRangeJSON: String? = nil, locatorJSON: String,
                readiumVersion: String? = nil, chapterTextHash: String? = nil,
                color: HighlightColor = .yellow, style: HighlightStyle = .highlight, note: String = "") {
        self.bookID = bookID
        self.chapterID = chapterID
        self.spineHref = spineHref
        self.chapterTitle = chapterTitle
        self.quoteExact = quoteExact
        self.quotePrefix = quotePrefix
        self.quoteSuffix = quoteSuffix
        self.charStart = charStart
        self.charEnd = charEnd
        self.wordIdx = wordIdx
        self.wordCount = wordCount
        self.progression = progression
        self.totalProgression = totalProgression
        self.position = position
        self.cssSelector = cssSelector
        self.partialCFI = partialCFI
        self.domRangeJSON = domRangeJSON
        self.locatorJSON = locatorJSON
        self.readiumVersion = readiumVersion
        self.chapterTextHash = chapterTextHash
        self.color = color
        self.style = style
        self.note = note
    }
}

/// One row of `dim_tag`. Names are deduped case-insensitively in code (no UNIQUE).
public struct TagRecord: Codable, Sendable, Equatable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dim_tag"

    public var id: String
    public var name: String?
    public var color: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "tag_id"
        case name
        case color
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

/// One row of `bridge_highlight_tag`. `(highlight_id, tag_id)` is deduped in code.
public struct HighlightTagRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bridge_highlight_tag"

    public var id: String
    public var highlightID: String?
    public var tagID: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "bridge_id"
        case highlightID = "highlight_id"
        case tagID = "tag_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

/// One row of `fact_bookmark`.
public struct BookmarkRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fact_bookmark"

    public var id: String
    public var bookID: String?
    /// Href key (fragment removed), for matching the current page.
    public var spineHref: String?
    public var progression: Double?
    public var locatorJSON: String?
    public var totalProgression: Double?
    public var label: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "bookmark_id"
        case bookID = "book_id"
        case spineHref = "spine_href"
        case progression
        case locatorJSON = "locator_json"
        case totalProgression = "total_progression"
        case label
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public typealias Columns = CodingKeys
}

public struct NewBookmark: Sendable, Equatable {
    public var bookID: String
    public var spineHref: String?
    public var progression: Double?
    public var locatorJSON: String
    public var totalProgression: Double?
    public var label: String?

    public init(bookID: String, spineHref: String?, progression: Double?, locatorJSON: String,
                totalProgression: Double?, label: String?) {
        self.bookID = bookID
        self.spineHref = spineHref
        self.progression = progression
        self.locatorJSON = locatorJSON
        self.totalProgression = totalProgression
        self.label = label
    }
}
