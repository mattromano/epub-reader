import Foundation
import GRDB
import Testing
@testable import Persistence

private func sampleBook(hash: String = "abc123", title: String = "Dune") -> NewBook {
    NewBook(contentHash: hash, title: title, authors: "Frank Herbert",
            fileRelpath: "Books/\(hash).epub", fileSizeBytes: 1024)
}

private func date(_ s: String) -> Date { Timestamp.date(from: s)! }

@Suite struct MigrationTests {
    @Test func migrationCreatesExpectedColumns() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let bookColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(dim_book)")
                .map { $0["name"] as String }
            #expect(bookColumns == [
                "book_id", "content_hash", "identifier", "title", "authors", "authors_json",
                "language", "publisher", "published_date", "epub_version", "layout",
                "reading_progression", "file_relpath", "file_size_bytes", "cover_relpath",
                "word_count", "chapter_count", "index_version", "status", "rating", "started_at",
                "finished_at", "last_locator_json", "last_total_progression", "last_opened_at",
                "preferences_json", "created_at", "updated_at", "deleted_at",
            ])
            let settingColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(app_setting)")
                .map { $0["name"] as String }
            #expect(settingColumns == [
                "setting_id", "key", "value_json", "created_at", "updated_at", "deleted_at",
            ])
            #expect(try db.tableExists("grdb_migrations"))
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(applied == ["v1_books"])
        }
    }

    @Test(arguments: [("dim_book", "book_id"), ("app_setting", "setting_id")])
    func singleTextPrimaryKeyAndEveryOtherColumnNullableOrDefaulted(table: String, pk: String) throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            let pkColumns = rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(pkColumns == [pk])
            let pkRow = try #require(rows.first { ($0["name"] as String) == pk })
            #expect((pkRow["type"] as String) == "TEXT")
            for row in rows where (row["name"] as String) != pk {
                let notNull = (row["notnull"] as Int) == 1
                let hasDefault = (row["dflt_value"] as String?) != nil
                #expect(!notNull || hasDefault, "\(table).\(row["name"] as String) is NOT NULL without DEFAULT")
            }
        }
    }

    @Test(arguments: ["dim_book", "app_setting"])
    func noUniqueIndexes(table: String) throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
            // A TEXT PK creates an automatic unique index with origin 'pk'; anything else unique is forbidden.
            let uniqueNonPK = indexes.filter { ($0["unique"] as Int) == 1 && ($0["origin"] as String) != "pk" }
            #expect(uniqueNonPK.isEmpty)
            let plain = indexes.filter { ($0["unique"] as Int) == 0 }.map { $0["name"] as String }
            #expect(plain.count == 1, "expected one plain index, got \(plain)")
        }
    }

    @Test func sqliteVersionCheck() {
        #expect(AppDatabase.isAtLeast("3.25.0", major: 3, minor: 25))
        #expect(AppDatabase.isAtLeast("3.46.1", major: 3, minor: 25))
        #expect(!AppDatabase.isAtLeast("3.24.9", major: 3, minor: 25))
        #expect(!AppDatabase.isAtLeast("2.99.0", major: 3, minor: 25))
    }

    @Test func openCreatesPoolInWALMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appendingPathComponent("Database/margins.sqlite"))
        let mode = try db.reader.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }
}

@Suite struct ImportTests {
    @Test func importingSameHashTwiceReturnsDuplicate() async throws {
        let db = try AppDatabase.inMemory()
        let first = try await db.importBook(sampleBook(), now: date("2026-11-22T07:00:00.000Z"))
        let second = try await db.importBook(sampleBook(title: "Dune (copy)"),
                                             now: date("2026-11-22T08:00:00.000Z"))

        guard case .inserted(let inserted) = first else {
            Issue.record("first import should insert, got \(first)"); return
        }
        guard case .duplicate(let existing) = second else {
            Issue.record("second import should be duplicate, got \(second)"); return
        }
        #expect(existing.id == inserted.id)
        #expect(existing.title == "Dune")
        #expect(inserted.createdAt == "2026-11-22T07:00:00.000Z")
        #expect(inserted.updatedAt == inserted.createdAt)
        #expect(inserted.status == "to_read")
        #expect(inserted.preferencesJSON == "{}")

        let count = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dim_book WHERE content_hash = ?",
                             arguments: ["abc123"])
        }
        #expect(count == 1)
    }

    @Test func softDeletedBookDoesNotBlockReimport() async throws {
        let db = try AppDatabase.inMemory()
        guard case .inserted(let original) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        try await db.softDeleteBook(id: original.id)
        #expect(try await db.book(id: original.id) == nil)
        let deletedAt = try await db.reader.read { db in
            try String.fetchOne(db, sql: "SELECT deleted_at FROM dim_book WHERE book_id = ?",
                                arguments: [original.id])
        }
        #expect(deletedAt != nil)

        guard case .inserted(let reimported) = try await db.importBook(sampleBook()) else {
            Issue.record("re-import after soft delete should insert"); return
        }
        #expect(reimported.id != original.id)
        let count = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dim_book WHERE content_hash = ?",
                             arguments: ["abc123"])
        }
        #expect(count == 2)  // soft delete keeps the old row
    }

    @Test func bookWithContentHashIgnoresSoftDeletedRows() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.book(withContentHash: "abc123") == nil)
        guard case .inserted(let original) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        #expect(try await db.book(withContentHash: "abc123")?.id == original.id)
        try await db.softDeleteBook(id: original.id)
        #expect(try await db.book(withContentHash: "abc123") == nil)
    }

    /// GRDB's async writes honour task cancellation. Callers (e.g. the reader's debounced
    /// resume save) must not cancel the task that performs the write.
    @Test func writesFromACancelledTaskAreNotApplied() async throws {
        let db = try AppDatabase.inMemory()
        guard case .inserted(let book) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await db.updateResumePoint(bookID: book.id, locatorJSON: "{}", totalProgression: 0.5)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await db.book(id: book.id)?.lastLocatorJSON == nil)
    }

    @Test func markOpenedSetsReadingAndStartedAtOnce() async throws {
        let db = try AppDatabase.inMemory()
        guard case .inserted(let book) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        try await db.markOpened(bookID: book.id, now: date("2026-11-22T09:00:00.000Z"))
        let afterFirst = try #require(try await db.book(id: book.id))
        #expect(afterFirst.status == "reading")
        #expect(afterFirst.startedAt == "2026-11-22T09:00:00.000Z")
        #expect(afterFirst.lastOpenedAt == "2026-11-22T09:00:00.000Z")
        #expect(afterFirst.updatedAt == "2026-11-22T09:00:00.000Z")

        try await db.markOpened(bookID: book.id, now: date("2026-11-23T10:00:00.000Z"))
        let afterSecond = try #require(try await db.book(id: book.id))
        #expect(afterSecond.status == "reading")
        #expect(afterSecond.startedAt == "2026-11-22T09:00:00.000Z")
        #expect(afterSecond.lastOpenedAt == "2026-11-23T10:00:00.000Z")
    }

    @Test func markOpenedKeepsFinishedStatus() async throws {
        let db = try AppDatabase.inMemory()
        guard case .inserted(let book) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE dim_book SET status = 'finished' WHERE book_id = ?",
                           arguments: [book.id])
        }
        try await db.markOpened(bookID: book.id)
        #expect(try await db.book(id: book.id)?.status == "finished")
    }

    @Test func updateResumePointStoresLocatorAndProgression() async throws {
        let db = try AppDatabase.inMemory()
        guard case .inserted(let book) = try await db.importBook(sampleBook()) else {
            Issue.record("expected insert"); return
        }
        let locator = #"{"href":"ch1.xhtml","locations":{"progression":0.5}}"#
        try await db.updateResumePoint(bookID: book.id, locatorJSON: locator, totalProgression: 0.42,
                                       now: date("2026-11-22T11:00:00.000Z"))
        let updated = try #require(try await db.book(id: book.id))
        #expect(updated.lastLocatorJSON == locator)
        #expect(updated.lastTotalProgression == 0.42)
        #expect(updated.updatedAt == "2026-11-22T11:00:00.000Z")
    }
}

@Suite struct LibraryRequestTests {
    @Test func allBooksExcludesDeletedAndOrdersByLastOpenedThenCreated() async throws {
        let db = try AppDatabase.inMemory()
        func insert(_ hash: String, _ created: String) async throws -> String {
            guard case .inserted(let b) = try await db.importBook(sampleBook(hash: hash, title: hash),
                                                                  now: date(created)) else {
                Issue.record("expected insert"); return ""
            }
            return b.id
        }
        let neverOpenedOld = try await insert("a", "2026-11-01T00:00:00.000Z")
        let neverOpenedNew = try await insert("b", "2026-11-02T00:00:00.000Z")
        let openedEarlier = try await insert("c", "2026-11-03T00:00:00.000Z")
        let openedLater = try await insert("d", "2026-11-04T00:00:00.000Z")
        let deleted = try await insert("e", "2026-11-05T00:00:00.000Z")

        try await db.markOpened(bookID: openedEarlier, now: date("2026-11-10T00:00:00.000Z"))
        try await db.markOpened(bookID: openedLater, now: date("2026-11-11T00:00:00.000Z"))
        try await db.markOpened(bookID: deleted, now: date("2026-11-12T00:00:00.000Z"))
        try await db.softDeleteBook(id: deleted)

        let ids = try await db.reader.read { db in
            try LibraryRequests.allBooks().fetchAll(db).map(\.id)
        }
        #expect(ids == [openedLater, openedEarlier, neverOpenedNew, neverOpenedOld])
    }
}

@Suite struct SettingTests {
    @Test func latestUpdatedAtWinsAmongNonDeletedRows() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { db in
            // Simulate sync duplicates for one key, plus a newer soft-deleted row that must be ignored.
            try db.execute(sql: """
                INSERT INTO app_setting (setting_id, key, value_json, created_at, updated_at, deleted_at)
                VALUES
                  ('s1', 'day_start_hour', '3', '2026-11-01T00:00:00.000Z', '2026-11-01T00:00:00.000Z', NULL),
                  ('s2', 'day_start_hour', '5', '2026-11-02T00:00:00.000Z', '2026-11-05T00:00:00.000Z', NULL),
                  ('s3', 'day_start_hour', '9', '2026-11-03T00:00:00.000Z', '2026-11-09T00:00:00.000Z',
                   '2026-11-09T00:00:00.000Z')
                """)
        }
        #expect(try await db.settingJSON(forKey: "day_start_hour") == "5")
        #expect(try await db.settingJSON(forKey: "missing") == nil)
    }

    @Test func setSettingInsertsThenUpdatesWithoutDuplicating() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setSettingJSON("4", forKey: "day_start_hour", now: date("2026-11-01T00:00:00.000Z"))
        try await db.setSettingJSON("6", forKey: "day_start_hour", now: date("2026-11-02T00:00:00.000Z"))
        #expect(try await db.settingJSON(forKey: "day_start_hour") == "6")
        let count = try await db.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_setting WHERE key = ?",
                             arguments: ["day_start_hour"])
        }
        #expect(count == 1)
    }
}

@Suite struct TimestampTests {
    @Test func formatsUTCWithMilliseconds() {
        let date = Date(timeIntervalSince1970: 1_795_333_271.123)  // 2026-11-22T07:41:11.123Z
        let s = Timestamp.string(from: date)
        #expect(s == "2026-11-22T07:41:11.123Z")
        #expect(s.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
    }

    @Test func zeroMillisecondsStillHaveThreeDigits() {
        #expect(Timestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
    }

    @Test func roundTrips() throws {
        let s = "2026-11-22T07:41:11.123Z"
        let parsed = try #require(Timestamp.date(from: s))
        #expect(Timestamp.string(from: parsed) == s)
        #expect(abs(parsed.timeIntervalSince1970 - 1_795_333_271.123) < 0.0005)
        #expect(Timestamp.date(from: "not a date") == nil)
    }
}
