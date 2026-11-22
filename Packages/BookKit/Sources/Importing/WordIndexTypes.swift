import Foundation

// Public contract for the word index (SPEC §5.2 dim_chapter / dim_word_anchor, §6.2).
// SCAFFOLD — types are final; function bodies are stubs Agent A replaces
// (Agent A may move them into TextNormalizer.swift / WordIndexer.swift / WordIndex.swift).

/// One reading-order resource, read by the app via Readium and handed over as plain values.
public struct IndexInputChapter: Sendable, Equatable {
    public var spineIndex: Int
    /// Href key (see app `HrefKey`): Readium href without fragment, as a string.
    public var href: String
    /// TOC title, if any ('Section N' is filled in by the indexer when nil).
    public var title: String?
    /// `linear="no"` items are excluded from book totals.
    public var isLinear: Bool
    /// Raw XHTML. Empty string if the resource couldn't be read (indexed as 0 words).
    public var xhtml: String

    public init(spineIndex: Int, href: String, title: String?, isLinear: Bool, xhtml: String) {
        self.spineIndex = spineIndex
        self.href = href
        self.title = title
        self.isLinear = isLinear
        self.xhtml = xhtml
    }
}

/// One `dim_word_anchor` row (without ids).
public struct BlockAnchor: Sendable, Equatable, Codable {
    public var blockIndex: Int
    /// Block start progression within the resource: charOffset / chapter charCount (0–1).
    public var progression: Double
    public var charOffset: Int
    /// Words before this block, within the chapter.
    public var cumWordOffset: Int

    public init(blockIndex: Int, progression: Double, charOffset: Int, cumWordOffset: Int) {
        self.blockIndex = blockIndex
        self.progression = progression
        self.charOffset = charOffset
        self.cumWordOffset = cumWordOffset
    }
}

/// One `dim_chapter` row plus its anchors.
public struct ChapterIndex: Sendable, Equatable, Codable {
    public var spineIndex: Int
    public var href: String
    public var title: String
    public var isLinear: Bool
    public var wordCount: Int
    public var charCount: Int
    /// Words before this chapter, counting linear chapters only.
    public var cumWordsStart: Int
    /// sha256 hex of the normalized chapter text.
    public var textHash: String
    public var anchors: [BlockAnchor]

    public init(spineIndex: Int, href: String, title: String, isLinear: Bool, wordCount: Int,
                charCount: Int, cumWordsStart: Int, textHash: String, anchors: [BlockAnchor]) {
        self.spineIndex = spineIndex
        self.href = href
        self.title = title
        self.isLinear = isLinear
        self.wordCount = wordCount
        self.charCount = charCount
        self.cumWordsStart = cumWordsStart
        self.textHash = textHash
        self.anchors = anchors
    }
}

/// Output of `TextNormalizer`: collapsed plain text plus the char offsets where blocks start.
public struct NormalizedText: Sendable, Equatable {
    public var text: String
    /// Ascending offsets (in `Character`s of `text`) of each block start; first is 0 when non-empty.
    public var blockStarts: [Int]

    public init(text: String, blockStarts: [Int]) {
        self.text = text
        self.blockStarts = blockStarts
    }
}

public enum TextNormalizer {
    /// Forgiving XHTML → normalized text (drops head/script/style, decodes entities,
    /// collapses whitespace, block boundaries at block-level tags). SCAFFOLD STUB.
    public static func normalize(xhtml: String) -> NormalizedText {
        NormalizedText(text: "", blockStarts: [])
    }
}

public enum WordIndexer {
    /// Stored in `dim_book.index_version`; bump to force a re-index.
    public static let version = 1

    /// Indexes chapters in spine order. SCAFFOLD STUB.
    public static func index(_ chapters: [IndexInputChapter]) -> [ChapterIndex] {
        []
    }
}

/// In-memory lookup: (href, progression) → book-level word index (SPEC §5.2 lookup).
public struct WordIndex: Sendable {
    public let bookID: String
    public let chapters: [ChapterIndex]

    public init(bookID: String, chapters: [ChapterIndex]) {
        self.bookID = bookID
        self.chapters = chapters
    }

    /// Total words over linear chapters.
    public var totalWords: Int { 0 } // SCAFFOLD STUB

    /// `dim_chapter.chapter_id` for `href`: "<book_id>:<spine_index>".
    public func chapterID(href: String) -> String? { nil } // SCAFFOLD STUB

    /// `cum_words_start` + interpolated `cum_word_offset` between the anchors around
    /// `progression`. Nil for unknown hrefs. Monotonic in progression. SCAFFOLD STUB.
    public func wordIdx(href: String, progression: Double) -> Int? { nil }

    /// Deterministic chapter id format shared by indexer, persistence and tracker.
    public static func chapterID(bookID: String, spineIndex: Int) -> String {
        "\(bookID):\(spineIndex)"
    }
}
