import Foundation
import GRDB
import Testing
@testable import Persistence

private let t0 = Timestamp.date(from: "2026-11-22T10:00:00.000Z")!

private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

private func ts(_ offset: Double) -> String { Timestamp.string(from: at(offset)) }

private func count(_ db: AppDatabase, _ table: String, where clause: String = "1 = 1") throws -> Int {
    try db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(clause)") ?? 0 }
}

private func fullHighlight(book: String = "book-1", total: Double = 0.5) -> NewHighlight {
    NewHighlight(bookID: book, chapterID: "book-1:3", spineHref: "OEBPS/ch3.xhtml", chapterTitle: "Three",
                 quoteExact: "the quoted text", quotePrefix: "before ", quoteSuffix: " after",
                 charStart: 120, charEnd: 135, wordIdx: 4200, wordCount: 3, progression: 0.25,
                 totalProgression: total, position: 17, cssSelector: "#p12", partialCFI: "/4/2",
                 domRangeJSON: "{\"start\":1}", locatorJSON: "{\"href\":\"ch3\"}", readiumVersion: "3.11.0",
                 chapterTextHash: "abc123", color: .green, style: .underline, note: "a note")
}

private func minimalHighlight(book: String = "book-1", total: Double? = nil) -> NewHighlight {
    NewHighlight(bookID: book, quoteExact: "q", totalProgression: total, locatorJSON: "{}")
}

private func bridgeRows(_ db: AppDatabase, highlight: String) throws -> [HighlightTagRecord] {
    try db.reader.read { db in
        try HighlightTagRecord.filter(HighlightTagRecord.Columns.highlightID == highlight).fetchAll(db)
    }
}

@Suite struct HighlightMigrationTests {
    private func columns(_ db: AppDatabase, _ table: String) throws -> [String] {
        try db.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        }
    }

    @Test func v4Columns() throws {
        let db = try AppDatabase.inMemory()
        #expect(try columns(db, "fact_highlight") == HighlightRecord.CodingKeys.allColumnNames)
        #expect(try columns(db, "dim_tag") == ["tag_id", "name", "color", "created_at", "updated_at", "deleted_at"])
        #expect(try columns(db, "bridge_highlight_tag") == [
            "bridge_id", "highlight_id", "tag_id", "created_at", "updated_at", "deleted_at",
        ])
        #expect(try columns(db, "fact_bookmark") == [
            "bookmark_id", "book_id", "spine_href", "progression", "locator_json", "total_progression",
            "label", "created_at", "updated_at", "deleted_at",
        ])
    }

    @Test(arguments: [("fact_highlight", "highlight_id"), ("dim_tag", "tag_id"),
                      ("bridge_highlight_tag", "bridge_id"), ("fact_bookmark", "bookmark_id")])
    func syncedTablesFollowSyncRules(table: String, pk: String) throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            #expect(rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String } == [pk])
            let pkRow = try #require(rows.first { ($0["name"] as String) == pk })
            #expect((pkRow["type"] as String) == "TEXT")
            for row in rows where (row["name"] as String) != pk {
                let notNull = (row["notnull"] as Int) == 1
                let hasDefault = (row["dflt_value"] as String?) != nil
                #expect(!notNull || hasDefault, "\(table).\(row["name"] as String) is NOT NULL without DEFAULT")
            }
            let names = rows.map { $0["name"] as String }
            #expect(names.contains("created_at") && names.contains("updated_at") && names.contains("deleted_at"))
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
            for index in indexes where (index["unique"] as Int) == 1 {
                #expect((index["origin"] as String) == "pk", "\(table) has a non-PK unique index")
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").isEmpty)
        }
    }

    @Test func highlightIndexes() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            func indexed(_ table: String) throws -> Set<[String]> {
                let names = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
                    .filter { ($0["origin"] as String) == "c" }.map { $0["name"] as String }
                return Set(try names.map { name in
                    try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] as String }
                })
            }
            let highlight = try indexed("fact_highlight")
            let bridge = try indexed("bridge_highlight_tag")
            let bookmark = try indexed("fact_bookmark")
            #expect(highlight.contains(["book_id", "total_progression"]))
            #expect(bridge.contains(["highlight_id", "tag_id"]))
            #expect(bridge.contains(["tag_id"]))
            #expect(bookmark.contains(["book_id", "total_progression"]))
        }
    }

    @Test func columnDefaults() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO fact_highlight (highlight_id) VALUES ('h')")
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM fact_highlight"))
            #expect(row["quote_exact"] as String == "")
            #expect(row["quote_prefix"] as String == "")
            #expect(row["quote_suffix"] as String == "")
            #expect(row["anchor_status"] as String == "exact")
            #expect(row["color"] as String == "yellow")
            #expect(row["note"] as String == "")
            #expect(row["style"] as String == "highlight")
        }
    }
}

private extension HighlightRecord.CodingKeys {
    static var allColumnNames: [String] {
        [Self.id, .bookID, .chapterID, .spineHref, .chapterTitle, .quoteExact, .quotePrefix, .quoteSuffix,
         .charStart, .charEnd, .wordIdx, .wordCount, .progression, .totalProgression, .position, .cssSelector,
         .partialCFI, .domRangeJSON, .locatorJSON, .readiumVersion, .chapterTextHash, .anchorStatus,
         .anchorScore, .lastAnchoredAt, .color, .note, .style, .exportReadwiseAt, .createdAt, .updatedAt,
         .deletedAt].map(\.rawValue)
    }
}

@Suite struct HighlightWriteTests {
    @Test func saveHighlightRoundTripsAllFields() async throws {
        let db = try AppDatabase.inMemory()
        let saved = try await db.saveHighlight(fullHighlight(), now: at(5))
        let fetched = try await db.reader.read { db in try HighlightRequests.highlight(id: saved.id).fetchOne(db) }
        #expect(fetched == saved)
        let h = try #require(fetched)
        #expect(UUID(uuidString: h.id) != nil)
        #expect(h.bookID == "book-1")
        #expect(h.chapterID == "book-1:3")
        #expect(h.spineHref == "OEBPS/ch3.xhtml")
        #expect(h.chapterTitle == "Three")
        #expect(h.quoteExact == "the quoted text")
        #expect(h.quotePrefix == "before ")
        #expect(h.quoteSuffix == " after")
        #expect(h.charStart == 120 && h.charEnd == 135)
        #expect(h.wordIdx == 4200 && h.wordCount == 3)
        #expect(h.progression == 0.25 && h.totalProgression == 0.5)
        #expect(h.position == 17)
        #expect(h.cssSelector == "#p12" && h.partialCFI == "/4/2" && h.domRangeJSON == "{\"start\":1}")
        #expect(h.locatorJSON == "{\"href\":\"ch3\"}")
        #expect(h.readiumVersion == "3.11.0" && h.chapterTextHash == "abc123")
        #expect(h.anchorStatus == "exact" && h.anchorScore == nil)
        #expect(h.color == "green" && h.highlightColor == .green)
        #expect(h.style == "underline" && h.highlightStyle == .underline)
        #expect(h.note == "a note")
        #expect(h.exportReadwiseAt == nil)
        #expect(h.lastAnchoredAt == ts(5) && h.createdAt == ts(5) && h.updatedAt == ts(5))
        #expect(h.deletedAt == nil)
    }

    @Test func saveHighlightDefaults() async throws {
        let db = try AppDatabase.inMemory()
        let saved = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let h = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(h.color == "yellow" && h.style == "highlight" && h.note == "")
        #expect(h.quotePrefix == "" && h.quoteSuffix == "")
        #expect(h.anchorStatus == "exact")
        #expect(h.charStart == nil && h.chapterID == nil)
    }

    @Test func highlightsInReadingOrder() async throws {
        let db = try AppDatabase.inMemory()
        let late = try await db.saveHighlight(minimalHighlight(total: 0.9), now: at(0))
        let early = try await db.saveHighlight(minimalHighlight(total: 0.1), now: at(1))
        let earlySecond = try await db.saveHighlight(minimalHighlight(total: 0.1), now: at(2))
        _ = try await db.saveHighlight(minimalHighlight(book: "book-2", total: 0.5), now: at(3))
        let ids = try await db.reader.read { db in
            try HighlightRequests.highlights(bookID: "book-1").fetchAll(db).map(\.id)
        }
        #expect(ids == [early.id, earlySecond.id, late.id])
    }

    @Test func updateHighlightChangesOnlyGivenFields() async throws {
        let db = try AppDatabase.inMemory()
        let saved = try await db.saveHighlight(fullHighlight(), now: at(0))

        try await db.updateHighlight(id: saved.id, color: .pink, now: at(10))
        var h = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(h.color == "pink" && h.style == "underline" && h.note == "a note")
        #expect(h.updatedAt == ts(10) && h.createdAt == ts(0))

        try await db.updateHighlight(id: saved.id, style: .highlight, note: "", now: at(20))
        h = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(h.color == "pink" && h.style == "highlight" && h.note == "")
        #expect(h.updatedAt == ts(20))
    }

    @Test func updateHighlightIsNoOpWhenDeletedOrMissing() async throws {
        let db = try AppDatabase.inMemory()
        let saved = try await db.saveHighlight(fullHighlight(), now: at(0))
        try await db.softDeleteHighlight(id: saved.id, now: at(5))
        try await db.updateHighlight(id: saved.id, color: .blue, note: "x", now: at(10))
        try await db.updateHighlight(id: "missing", color: .blue, now: at(10))
        let h = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(h.color == "green" && h.note == "a note" && h.updatedAt == ts(5))
        #expect(try count(db, "fact_highlight") == 1)
    }

    @Test func softDeleteHighlightCascadesToBridgeRows() async throws {
        let db = try AppDatabase.inMemory()
        let saved = try await db.saveHighlight(fullHighlight(), now: at(0))
        let other = try await db.saveHighlight(minimalHighlight(), now: at(0))
        try await db.addTag(name: "Work", toHighlight: saved.id, now: at(1))
        try await db.addTag(name: "Idea", toHighlight: saved.id, now: at(1))
        try await db.addTag(name: "Work", toHighlight: other.id, now: at(1))

        try await db.softDeleteHighlight(id: saved.id, now: at(9))

        let h = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(h.deletedAt == ts(9) && h.updatedAt == ts(9))
        let bridges = try bridgeRows(db, highlight: saved.id)
        #expect(bridges.count == 2)
        #expect(bridges.allSatisfy { $0.deletedAt == ts(9) && $0.updatedAt == ts(9) })
        #expect(try bridgeRows(db, highlight: other.id).allSatisfy { $0.deletedAt == nil })
        #expect(try count(db, "dim_tag", where: "deleted_at IS NULL") == 2)

        let visible = try await db.reader.read { db in
            (try HighlightRequests.highlights(bookID: "book-1").fetchAll(db).map(\.id),
             try HighlightRequests.highlight(id: saved.id).fetchOne(db))
        }
        #expect(visible.0 == [other.id])
        #expect(visible.1 == nil)

        // A second delete keeps the original timestamp.
        try await db.softDeleteHighlight(id: saved.id, now: at(20))
        let again = try #require(try await db.reader.read { db in try HighlightRecord.fetchOne(db, key: saved.id) })
        #expect(again.deletedAt == ts(9))
    }
}

@Suite struct TagTests {
    @Test func caseInsensitiveDedupeAcrossHighlights() async throws {
        let db = try AppDatabase.inMemory()
        let a = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let b = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let first = try #require(try await db.addTag(name: "Work", toHighlight: a.id, now: at(1)))
        let second = try #require(try await db.addTag(name: "work", toHighlight: b.id, now: at(2)))
        #expect(first.id == second.id)
        #expect(second.name == "Work")
        #expect(try count(db, "dim_tag") == 1)
        #expect(try count(db, "bridge_highlight_tag") == 2)
    }

    @Test func nonASCIICaseInsensitiveDedupe() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let first = try #require(try await db.addTag(name: "Ünï", toHighlight: h.id, now: at(1)))
        let second = try #require(try await db.addTag(name: "üNÏ", toHighlight: h.id, now: at(2)))
        #expect(first.id == second.id)
        #expect(try count(db, "dim_tag") == 1)
        #expect(try count(db, "bridge_highlight_tag") == 1)
    }

    @Test func trimsAndRejectsEmptyNames() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let tag = try #require(try await db.addTag(name: "  \n Travel\t ", toHighlight: h.id, now: at(1)))
        #expect(tag.name == "Travel")
        #expect(UUID(uuidString: tag.id) != nil)
        #expect(tag.createdAt == ts(1) && tag.updatedAt == ts(1) && tag.deletedAt == nil)
        #expect(try await db.addTag(name: "   \n", toHighlight: h.id, now: at(2)) == nil)
        #expect(try await db.addTag(name: "", toHighlight: h.id, now: at(2)) == nil)
        #expect(try count(db, "dim_tag") == 1)
    }

    @Test func samePairTwiceGivesOneBridgeRow() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        try await db.addTag(name: "Work", toHighlight: h.id, now: at(1))
        try await db.addTag(name: "WORK ", toHighlight: h.id, now: at(2))
        let bridges = try bridgeRows(db, highlight: h.id)
        #expect(bridges.count == 1)
        #expect(bridges.first?.createdAt == ts(1))
    }

    @Test func deletedOrMissingHighlightWritesNothing() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        try await db.softDeleteHighlight(id: h.id, now: at(1))
        #expect(try await db.addTag(name: "Work", toHighlight: h.id, now: at(2)) == nil)
        #expect(try await db.addTag(name: "Work", toHighlight: "missing", now: at(2)) == nil)
        #expect(try count(db, "dim_tag") == 0)
        #expect(try count(db, "bridge_highlight_tag") == 0)
    }

    @Test func removeThenReAddCreatesNewBridgeRow() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let tag = try #require(try await db.addTag(name: "Work", toHighlight: h.id, now: at(1)))
        try await db.removeTag(tagID: tag.id, fromHighlight: h.id, now: at(2))

        var bridges = try bridgeRows(db, highlight: h.id)
        #expect(bridges.count == 1 && bridges[0].deletedAt == ts(2) && bridges[0].updatedAt == ts(2))
        #expect(try count(db, "dim_tag", where: "deleted_at IS NULL") == 1)

        let again = try #require(try await db.addTag(name: "work", toHighlight: h.id, now: at(3)))
        #expect(again.id == tag.id)
        bridges = try bridgeRows(db, highlight: h.id)
        #expect(bridges.count == 2)
        #expect(bridges.filter { $0.deletedAt == nil }.map(\.createdAt) == [ts(3)])
    }

    @Test func tagsForHighlightOrderedAndFiltered() async throws {
        let db = try AppDatabase.inMemory()
        let h = try await db.saveHighlight(minimalHighlight(), now: at(0))
        let other = try await db.saveHighlight(minimalHighlight(), now: at(0))
        try await db.addTag(name: "zebra", toHighlight: h.id, now: at(1))
        try await db.addTag(name: "apple", toHighlight: h.id, now: at(2))
        let mango = try #require(try await db.addTag(name: "mango", toHighlight: h.id, now: at(3)))
        try await db.addTag(name: "Banana", toHighlight: h.id, now: at(4))
        try await db.addTag(name: "Other", toHighlight: other.id, now: at(5))
        try await db.removeTag(tagID: mango.id, fromHighlight: h.id, now: at(6))

        // A duplicate live bridge row (e.g. from sync) must not duplicate the tag.
        let banana = try await db.reader.read { db in
            try TagRecord.filter(TagRecord.Columns.name == "Banana").fetchOne(db)
        }
        try await db.writer.write { db in
            try HighlightTagRecord(id: UUID().uuidString, highlightID: h.id, tagID: banana?.id,
                                   createdAt: ts(7), updatedAt: ts(7), deletedAt: nil).insert(db)
        }

        let names = try await db.reader.read { db in
            try TagRequests.tags(forHighlightID: h.id).fetchAll(db).map(\.name)
        }
        #expect(names == ["apple", "Banana", "zebra"])

        let all = try await db.reader.read { db in try TagRequests.all().fetchAll(db).map(\.name) }
        #expect(all == ["apple", "Banana", "mango", "Other", "zebra"])
    }
}

@Suite struct BookmarkAndSettingTests {
    @Test func bookmarksAddListSoftDelete() async throws {
        let db = try AppDatabase.inMemory()
        let late = try await db.addBookmark(
            NewBookmark(bookID: "book-1", spineHref: "OEBPS/ch9.xhtml", progression: 0.4,
                        locatorJSON: "{\"p\":9}", totalProgression: 0.8, label: "Late"), now: at(0))
        let early = try await db.addBookmark(
            NewBookmark(bookID: "book-1", spineHref: "OEBPS/ch1.xhtml", progression: 0.1,
                        locatorJSON: "{\"p\":1}", totalProgression: 0.1, label: nil), now: at(1))
        _ = try await db.addBookmark(
            NewBookmark(bookID: "book-2", spineHref: nil, progression: nil, locatorJSON: "{}",
                        totalProgression: nil, label: nil), now: at(2))

        #expect(UUID(uuidString: late.id) != nil)
        let stored = try #require(try await db.reader.read { db in try BookmarkRecord.fetchOne(db, key: late.id) })
        #expect(stored == late)
        #expect(stored.spineHref == "OEBPS/ch9.xhtml" && stored.progression == 0.4 && stored.label == "Late")
        #expect(stored.locatorJSON == "{\"p\":9}" && stored.totalProgression == 0.8)
        #expect(stored.createdAt == ts(0) && stored.updatedAt == ts(0) && stored.deletedAt == nil)

        var ids = try await db.reader.read { db in try BookmarkRequests.bookmarks(bookID: "book-1").fetchAll(db).map(\.id) }
        #expect(ids == [early.id, late.id])

        try await db.softDeleteBookmark(id: early.id, now: at(10))
        ids = try await db.reader.read { db in try BookmarkRequests.bookmarks(bookID: "book-1").fetchAll(db).map(\.id) }
        #expect(ids == [late.id])
        let deleted = try #require(try await db.reader.read { db in try BookmarkRecord.fetchOne(db, key: early.id) })
        #expect(deleted.deletedAt == ts(10) && deleted.updatedAt == ts(10))
        #expect(try count(db, "fact_bookmark") == 3)
    }

    @Test func lastHighlightColorDefaultAndRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await db.lastHighlightColor() == .yellow)
        try await db.setLastHighlightColor(.green, now: at(1))
        #expect(try await db.lastHighlightColor() == .green)
        #expect(try await db.settingJSON(forKey: "last_highlight_color") == "\"green\"")
        try await db.setLastHighlightColor(.purple, now: at(2))
        #expect(try await db.lastHighlightColor() == .purple)
        #expect(try count(db, "app_setting", where: "key = 'last_highlight_color'") == 1)
    }

    @Test func unknownStoredColorFallsBackToYellow() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setSettingJSON("\"magenta\"", forKey: "last_highlight_color", now: at(1))
        #expect(try await db.lastHighlightColor() == .yellow)
        try await db.setSettingJSON("42", forKey: "last_highlight_color", now: at(2))
        #expect(try await db.lastHighlightColor() == .yellow)
    }
}
