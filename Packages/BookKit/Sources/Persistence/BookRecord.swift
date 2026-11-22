import Foundation
import GRDB

/// One row of `dim_book` (SPEC §5.2). Synced table: UUID PK, soft delete only.
public struct BookRecord: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "dim_book"

    public var id: String
    public var contentHash: String
    public var identifier: String?
    public var title: String
    public var authors: String
    public var authorsJSON: String
    public var language: String?
    public var publisher: String?
    public var publishedDate: String?
    public var epubVersion: String?
    public var layout: String
    public var readingProgression: String
    public var fileRelpath: String?
    public var fileSizeBytes: Int
    public var coverRelpath: String?
    public var wordCount: Int?
    public var chapterCount: Int?
    public var indexVersion: Int
    public var status: String
    public var rating: Int?
    public var startedAt: String?
    public var finishedAt: String?
    public var lastLocatorJSON: String?
    public var lastTotalProgression: Double
    public var lastOpenedAt: String?
    public var preferencesJSON: String
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?

    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id = "book_id"
        case contentHash = "content_hash"
        case identifier
        case title
        case authors
        case authorsJSON = "authors_json"
        case language
        case publisher
        case publishedDate = "published_date"
        case epubVersion = "epub_version"
        case layout
        case readingProgression = "reading_progression"
        case fileRelpath = "file_relpath"
        case fileSizeBytes = "file_size_bytes"
        case coverRelpath = "cover_relpath"
        case wordCount = "word_count"
        case chapterCount = "chapter_count"
        case indexVersion = "index_version"
        case status
        case rating
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case lastLocatorJSON = "last_locator_json"
        case lastTotalProgression = "last_total_progression"
        case lastOpenedAt = "last_opened_at"
        case preferencesJSON = "preferences_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    /// Typed column references for query-interface requests.
    public typealias Columns = CodingKeys
}

/// What the app hands to importBook after parsing with Readium.
public struct NewBook: Sendable, Equatable {
    public var contentHash: String
    public var identifier: String?
    public var title: String
    public var authors: String
    public var authorsJSON: String
    public var language: String?
    public var publisher: String?
    public var publishedDate: String?
    public var epubVersion: String?
    public var layout: String
    public var readingProgression: String
    public var fileRelpath: String
    public var fileSizeBytes: Int
    public var coverRelpath: String?

    public init(contentHash: String, identifier: String? = nil, title: String, authors: String,
                authorsJSON: String = "[]", language: String? = nil, publisher: String? = nil,
                publishedDate: String? = nil, epubVersion: String? = nil,
                layout: String = "reflowable", readingProgression: String = "ltr",
                fileRelpath: String, fileSizeBytes: Int, coverRelpath: String? = nil) {
        self.contentHash = contentHash
        self.identifier = identifier
        self.title = title
        self.authors = authors
        self.authorsJSON = authorsJSON
        self.language = language
        self.publisher = publisher
        self.publishedDate = publishedDate
        self.epubVersion = epubVersion
        self.layout = layout
        self.readingProgression = readingProgression
        self.fileRelpath = fileRelpath
        self.fileSizeBytes = fileSizeBytes
        self.coverRelpath = coverRelpath
    }
}

public enum ImportResult: Sendable, Equatable {
    case inserted(BookRecord)
    /// Existing non-deleted row with the same content_hash.
    case duplicate(BookRecord)
}

extension BookRecord {
    /// A fresh row for a newly imported book, with SPEC §5.2 defaults for everything else.
    init(id: String, newBook b: NewBook, now: String) {
        self.init(
            id: id, contentHash: b.contentHash, identifier: b.identifier, title: b.title,
            authors: b.authors, authorsJSON: b.authorsJSON, language: b.language,
            publisher: b.publisher, publishedDate: b.publishedDate, epubVersion: b.epubVersion,
            layout: b.layout, readingProgression: b.readingProgression, fileRelpath: b.fileRelpath,
            fileSizeBytes: b.fileSizeBytes, coverRelpath: b.coverRelpath, wordCount: nil,
            chapterCount: nil, indexVersion: 0, status: "to_read", rating: nil, startedAt: nil,
            finishedAt: nil, lastLocatorJSON: nil, lastTotalProgression: 0, lastOpenedAt: nil,
            preferencesJSON: "{}", createdAt: now, updatedAt: now, deletedAt: nil
        )
    }
}
