import Foundation
import GRDB

public enum AppDatabaseError: Error, Equatable {
    case sqliteTooOld(String)
}

/// The single database for the app. All writes go through methods on this type.
/// `Sendable` without `@unchecked`: the only stored property is a GRDB writer, which is Sendable.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    /// Runs the migrator. Throws AppDatabaseError.sqliteTooOld if sqlite_version() < 3.25.0.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        let version = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
        }
        guard Self.isAtLeast(version, major: 3, minor: 25) else {
            throw AppDatabaseError.sqliteTooOld(version)
        }
        try Self.migrator.migrate(writer)
    }

    /// DatabasePool at `url`, creating the parent directory. WAL mode.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // DatabasePool always uses WAL journal mode.
        let pool = try DatabasePool(path: url.path, configuration: Configuration())
        return try AppDatabase(pool)
    }

    /// DatabaseQueue in memory, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static func isAtLeast(_ version: String, major: Int, minor: Int) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let maj = parts.first ?? 0
        let min = parts.count > 1 ? parts[1] : 0
        return (maj, min) >= (major, minor)
    }

    // MARK: - Migrations

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // SPEC §5.2. Synced tables: one TEXT UUID PK, no other UNIQUE constraint,
        // every other column nullable or DEFAULT.
        migrator.registerMigration("v1_books") { db in
            try db.execute(sql: """
                CREATE TABLE dim_book (
                    book_id TEXT PRIMARY KEY NOT NULL,
                    content_hash TEXT NOT NULL DEFAULT '',
                    identifier TEXT,
                    title TEXT DEFAULT '',
                    authors TEXT DEFAULT '',
                    authors_json TEXT DEFAULT '[]',
                    language TEXT,
                    publisher TEXT,
                    published_date TEXT,
                    epub_version TEXT,
                    layout TEXT DEFAULT 'reflowable',
                    reading_progression TEXT DEFAULT 'ltr',
                    file_relpath TEXT,
                    file_size_bytes INTEGER DEFAULT 0,
                    cover_relpath TEXT,
                    word_count INTEGER,
                    chapter_count INTEGER,
                    index_version INTEGER DEFAULT 0,
                    status TEXT DEFAULT 'to_read',
                    rating INTEGER,
                    started_at TEXT,
                    finished_at TEXT,
                    last_locator_json TEXT,
                    last_total_progression REAL DEFAULT 0,
                    last_opened_at TEXT,
                    preferences_json TEXT DEFAULT '{}',
                    created_at TEXT,
                    updated_at TEXT,
                    deleted_at TEXT
                );
                CREATE INDEX idx_dim_book_content_hash ON dim_book (content_hash);

                CREATE TABLE app_setting (
                    setting_id TEXT PRIMARY KEY NOT NULL,
                    key TEXT NOT NULL DEFAULT '',
                    value_json TEXT NOT NULL DEFAULT 'null',
                    created_at TEXT,
                    updated_at TEXT,
                    deleted_at TEXT
                );
                CREATE INDEX idx_app_setting_key ON app_setting (key);
                """)
        }

        return migrator
    }

    // MARK: - Books

    /// Dedupe in code inside ONE write transaction: if a non-deleted dim_book with this content_hash
    /// exists, return .duplicate(existing); else insert with new UUID, created_at = updated_at = now.
    public func importBook(_ book: NewBook, now: Date = Date()) async throws -> ImportResult {
        let nowString = Timestamp.string(from: now)
        return try await writer.write { db in
            let existing = try BookRecord
                .filter(BookRecord.Columns.contentHash == book.contentHash)
                .filter(BookRecord.Columns.deletedAt == nil)
                .order(BookRecord.Columns.createdAt.asc)
                .fetchOne(db)
            if let existing {
                return .duplicate(existing)
            }
            let record = BookRecord(id: UUID().uuidString, newBook: book, now: nowString)
            try record.insert(db)
            return .inserted(record)
        }
    }

    /// Non-deleted book by id (soft-deleted rows are treated as absent).
    public func book(id: String) async throws -> BookRecord? {
        try await writer.read { db in
            try BookRecord
                .filter(BookRecord.Columns.id == id)
                .filter(BookRecord.Columns.deletedAt == nil)
                .fetchOne(db)
        }
    }

    /// The oldest non-deleted book with this content hash (same rule `importBook` dedupes on).
    public func book(withContentHash contentHash: String) async throws -> BookRecord? {
        try await writer.read { db in
            try BookRecord
                .filter(BookRecord.Columns.contentHash == contentHash)
                .filter(BookRecord.Columns.deletedAt == nil)
                .order(BookRecord.Columns.createdAt.asc)
                .fetchOne(db)
        }
    }

    public func updateResumePoint(bookID: String, locatorJSON: String, totalProgression: Double,
                                  now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET last_locator_json = ?, last_total_progression = ?, updated_at = ?
                    WHERE book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [locatorJSON, totalProgression, nowString, bookID])
        }
    }

    /// Sets last_opened_at and updated_at; status to_read -> reading; started_at if nil.
    public func markOpened(bookID: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET last_opened_at = :now,
                        updated_at = :now,
                        status = CASE WHEN status = 'to_read' THEN 'reading' ELSE status END,
                        started_at = COALESCE(started_at, :now)
                    WHERE book_id = :id AND deleted_at IS NULL
                    """,
                arguments: ["now": nowString, "id": bookID])
        }
    }

    public func updatePreferences(bookID: String, preferencesJSON: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET preferences_json = ?, updated_at = ?
                    WHERE book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [preferencesJSON, nowString, bookID])
        }
    }

    /// Sets status and updated_at. `.finished` also sets finished_at once (first finish wins);
    /// other statuses leave started_at / finished_at untouched.
    public func setStatus(bookID: String, status: BookStatus, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET status = :status,
                        updated_at = :now,
                        finished_at = CASE WHEN :status = 'finished'
                                           THEN COALESCE(finished_at, :now) ELSE finished_at END
                    WHERE book_id = :id AND deleted_at IS NULL
                    """,
                arguments: ["status": status.rawValue, "now": nowString, "id": bookID])
        }
    }

    public func softDeleteBook(id: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE dim_book
                    SET deleted_at = ?, updated_at = ?
                    WHERE book_id = ? AND deleted_at IS NULL
                    """,
                arguments: [nowString, nowString, id])
        }
    }

    // MARK: - Settings

    /// app_setting: latest updated_at wins among non-deleted rows with this key.
    public func settingJSON(forKey key: String) async throws -> String? {
        try await writer.read { db in
            try Self.currentSetting(db, key: key)?.valueJSON
        }
    }

    /// Updates the winning row for `key` if one exists, otherwise inserts a new row.
    public func setSettingJSON(_ valueJSON: String, forKey key: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            if var current = try Self.currentSetting(db, key: key) {
                current.valueJSON = valueJSON
                current.updatedAt = nowString
                try current.update(db)
            } else {
                let record = AppSettingRecord(
                    id: UUID().uuidString, key: key, valueJSON: valueJSON,
                    createdAt: nowString, updatedAt: nowString, deletedAt: nil)
                try record.insert(db)
            }
        }
    }

    private static func currentSetting(_ db: Database, key: String) throws -> AppSettingRecord? {
        try AppSettingRecord
            .filter(AppSettingRecord.Columns.key == key)
            .filter(AppSettingRecord.Columns.deletedAt == nil)
            .order(AppSettingRecord.Columns.updatedAt.desc)
            .fetchOne(db)
    }
}
