import Foundation
import GRDB
import Importing
@testable import Persistence
import Testing

@Suite struct BackupTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func newBook(_ hash: String) -> NewBook {
        NewBook(contentHash: hash, title: "Book \(hash)", authors: "A", fileRelpath: BookPaths.bookRelpath(contentHash: hash),
                fileSizeBytes: 3)
    }

    @Test func snapshotIsAReadableCopyOfALiveWALDatabase() async throws {
        let dir = try tempDir()
        let database = try AppDatabase.open(at: dir.appendingPathComponent("live/margins.sqlite"))
        _ = try await database.importBook(newBook("aaa"))

        let copy = dir.appendingPathComponent("copy.sqlite")
        try await database.snapshot(to: copy)

        for sidecar in ["-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: copy.path + sidecar))
        }
        let header = try Data(contentsOf: copy).subdata(in: 18 ..< 20)
        #expect(header == Data([1, 1]))  // rollback-journal file format, not WAL (2, 2)
        let reopened = try DatabaseQueue(path: copy.path)
        let titles = try await reopened.read { try String.fetchAll($0, sql: "SELECT title FROM dim_book") }
        #expect(titles == ["Book aaa"])
        let migrations = try await reopened.read { try AppDatabase.migrator.appliedIdentifiers($0) }
        #expect(migrations.contains("v7_readwise"))
    }

    @Test func snapshotRefusesToOverwrite() async throws {
        let dir = try tempDir()
        let database = try AppDatabase.inMemory()
        let copy = dir.appendingPathComponent("copy.sqlite")
        try Data("x".utf8).write(to: copy)
        await #expect(throws: (any Error).self) { try await database.snapshot(to: copy) }
    }

    @Test func libraryBackupHoldsDatabaseBooksCoversAndManifest() async throws {
        let dir = try tempDir()
        let container = dir.appendingPathComponent("container", isDirectory: true)
        let database = try AppDatabase.open(at: BookPaths.resolve(BookPaths.databaseRelpath, in: container))
        _ = try await database.importBook(newBook("aaa"))
        let fm = FileManager.default
        try fm.createDirectory(at: container.appendingPathComponent("Books"), withIntermediateDirectories: true)
        try fm.createDirectory(at: container.appendingPathComponent("Covers"), withIntermediateDirectories: true)
        try Data("epub".utf8).write(to: BookPaths.resolve(BookPaths.bookRelpath(contentHash: "aaa"), in: container))
        try Data("png".utf8).write(to: BookPaths.resolve(BookPaths.coverRelpath(contentHash: "aaa"), in: container))

        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-23T15:04:05Z"))
        let folder = try await LibraryBackup.makeFolder(
            database: database, container: container, in: dir.appendingPathComponent("out"), now: now,
            timeZone: try #require(TimeZone(identifier: "UTC")))

        #expect(folder.lastPathComponent == "Margins Backup 2026-11-23 150405")
        let db = try DatabaseQueue(path: folder.appendingPathComponent(BookPaths.databaseRelpath).path)
        #expect(try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dim_book") } == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Books/aaa.epub")) == Data("epub".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("Covers/aaa.png")) == Data("png".utf8))

        let manifest = try JSONDecoder().decode(
            LibraryBackup.Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        #expect(manifest.createdAt == "2026-11-23T15:04:05.000Z")
        #expect(manifest.schemaVersion == "v7_readwise")
        #expect(manifest.bookCount == 1)
        // The live library is untouched.
        #expect(fm.fileExists(atPath: container.appendingPathComponent("Books/aaa.epub").path))
    }

    @Test func libraryBackupWorksWithNoBooksOrCovers() async throws {
        let dir = try tempDir()
        let container = dir.appendingPathComponent("container", isDirectory: true)
        let database = try AppDatabase.open(at: BookPaths.resolve(BookPaths.databaseRelpath, in: container))
        let folder = try await LibraryBackup.makeFolder(
            database: database, container: container, in: dir.appendingPathComponent("out"), now: Date())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(BookPaths.databaseRelpath).path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Books").path))
    }

    @Test func zipProducesOneArchive() async throws {
        let dir = try tempDir()
        let container = dir.appendingPathComponent("container", isDirectory: true)
        let database = try AppDatabase.open(at: BookPaths.resolve(BookPaths.databaseRelpath, in: container))
        let folder = try await LibraryBackup.makeFolder(
            database: database, container: container, in: dir.appendingPathComponent("out"), now: Date())
        let zip = try LibraryBackup.zip(folder: folder)
        #expect(zip.pathExtension == "zip")
        #expect(zip.deletingPathExtension().lastPathComponent == folder.lastPathComponent)
        let bytes = try Data(contentsOf: zip)
        #expect(bytes.prefix(2) == Data("PK".utf8))
    }
}
