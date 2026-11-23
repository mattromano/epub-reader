import Foundation
import GRDB
import Importing

extension AppDatabase {
    /// Writes a consistent, self-contained copy of the database to `url` (SQLite online backup:
    /// safe while the app keeps reading and writing). Fails if `url` already exists.
    public func snapshot(to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = writer
        try await Task.detached(priority: .userInitiated) {
            let destination = try DatabaseQueue(path: url.path)
            try source.backup(to: destination)
            // The copied header says WAL (like the source). Switch to a rollback journal so the
            // backup is one file that opens anywhere without a -wal sidecar.
            try destination.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try destination.close()
            for sidecar in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + sidecar)
            }
        }.value
    }
}

/// "Back up data" in Settings: the database, every EPUB and every cover in one folder laid out
/// like the App Group container (`Database/margins.sqlite`, `Books/`, `Covers/`), so restoring
/// is a copy back. Stored paths are relative, so a backup stays valid on another install.
public enum LibraryBackup {
    public struct Manifest: Codable, Equatable, Sendable {
        public var createdAt: String
        /// The last applied migration identifier.
        public var schemaVersion: String
        public var bookCount: Int
        public var highlightCount: Int
        public var sessionCount: Int
    }

    /// Builds `Margins Backup <local date time>` inside `parent` and returns its URL.
    public static func makeFolder(database: AppDatabase, container: URL, in parent: URL,
                                  now: Date = Date(), timeZone: TimeZone = .current) async throws -> URL {
        let fileManager = FileManager.default
        let folder = parent.appendingPathComponent(folderName(now: now, timeZone: timeZone), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        try await database.snapshot(to: BookPaths.resolve(BookPaths.databaseRelpath, in: folder))
        for directory in [BookPaths.booksDirectory, BookPaths.coversDirectory] {
            let source = container.appendingPathComponent(directory, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: folder.appendingPathComponent(directory, isDirectory: true))
        }

        let manifest = try await database.reader.read { db in
            Manifest(
                createdAt: Timestamp.string(from: now),
                schemaVersion: try AppDatabase.migrator.appliedIdentifiers(db).sorted().last ?? "",
                bookCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dim_book WHERE deleted_at IS NULL") ?? 0,
                highlightCount: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM fact_highlight WHERE deleted_at IS NULL") ?? 0,
                sessionCount: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM fact_reading_session WHERE deleted_at IS NULL") ?? 0)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return folder
    }

    /// Zips `folder` into `<folder>.zip` next to it (system zip via NSFileCoordinator).
    public static func zip(folder: URL) throws -> URL {
        let destination = folder.deletingLastPathComponent()
            .appendingPathComponent(folder.lastPathComponent).appendingPathExtension("zip")
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    static func folderName(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Margins Backup \(formatter.string(from: now))"
    }
}
