import Foundation
import GRDB
import Testing
import Tracking
@testable import Persistence

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Timestamp.date(from: "2026-11-22T10:00:00.000Z")!

private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

private let context = SessionContext(bookID: "book-1", deviceID: "device-1", readingMode: "paginated",
                                     fontSize: 1.0, isFixedLayout: false)

private func page(_ w: Int) -> TrackerEvent {
    .location(LocationSample(kind: .pageTurn, wordIdx: w, chapterID: "book-1:2", progression: 0.5,
                             totalProgression: 0.25, locatorJSON: "{\"w\":\(w)}"))
}

/// Drives a tracker through `steps` (offset seconds from t0) and returns all outputs.
private func drive(_ steps: [(Double, TrackerEvent)]) -> (SessionTracker, [TrackerOutput]) {
    var tracker = SessionTracker(config: TrackerConfig(timeZone: utc))
    var out: [TrackerOutput] = []
    for (o, e) in steps { out += tracker.handle(e, at: at(o)) }
    return (tracker, out)
}

/// Persists outputs the way the app driver does.
private func persist(_ outputs: [TrackerOutput], in db: AppDatabase) async throws {
    for output in outputs {
        switch output {
        case .locationEvent(let row): try await db.appendLocationEvents([row])
        case .checkpoint(let draft): try await db.saveCheckpoint(draft)
        case .sessionEnded(let row): try await db.finishSession(row, now: at(1000))
        case .sessionDiscarded(let id): try await db.discardSession(id: id)
        }
    }
}

private func sampleRow(id: String = "session-1") -> SessionRow {
    SessionRow(sessionID: id, bookID: "book-1", deviceID: "device-1", startedAt: at(0), endedAt: at(600),
               localDate: "2026-11-22", localStartHour: 10, tzOffsetMinutes: 0, wallSeconds: 600,
               activeSeconds: 540, startWordIdx: 1000, endWordIdx: 3500, wordsRead: 2500,
               startTotalProgression: 0.1, endTotalProgression: 0.2, startLocatorJSON: "{}",
               endLocatorJSON: "{}", pageTurns: 10, jumpCount: 1, readingMode: "paginated", fontSize: 1.0,
               endReason: .closed, isPaceEligible: true)
}

private func sampleDraft(id: String = "session-1") -> SessionDraft {
    SessionDraft(sessionID: id, bookID: "book-1", startedAt: at(0), lastCheckpointAt: at(30), stateJSON: "{}")
}

private func count(_ db: AppDatabase, _ table: String, where clause: String = "1 = 1") throws -> Int {
    try db.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(clause)") ?? 0 }
}

@Suite struct SessionMigrationTests {
    private func columns(_ db: AppDatabase, _ table: String) throws -> [String] {
        try db.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        }
    }

    @Test func v3Columns() throws {
        let db = try AppDatabase.inMemory()
        #expect(try columns(db, "fact_reading_session") == [
            "session_id", "book_id", "device_id", "started_at", "ended_at", "local_date",
            "local_start_hour", "tz_offset_minutes", "wall_seconds", "active_seconds",
            "start_word_idx", "end_word_idx", "words_read", "start_total_progression",
            "end_total_progression", "start_locator_json", "end_locator_json", "page_turns",
            "jump_count", "reading_mode", "font_size", "end_reason", "is_pace_eligible",
            "is_user_edited", "created_at", "updated_at", "deleted_at",
        ])
        #expect(try columns(db, "fact_location_event") == [
            "event_id", "session_id", "book_id", "occurred_at", "event_type", "chapter_id",
            "progression", "total_progression", "word_idx", "words_delta", "seconds_since_prev",
            "is_counted", "locator_json",
        ])
        #expect(try columns(db, "session_draft") == [
            "session_id", "book_id", "started_at", "last_checkpoint_at", "state_json",
        ])
        #expect(try columns(db, "dim_device") == [
            "device_id", "name", "model", "first_seen_at", "created_at", "updated_at", "deleted_at",
        ])
    }

    @Test(arguments: [("fact_reading_session", "session_id"), ("dim_device", "device_id")])
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
            let indexes = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
            for index in indexes where (index["unique"] as Int) == 1 {
                #expect((index["origin"] as String) == "pk", "\(table) has a non-PK unique index")
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").isEmpty)
        }
    }

    @Test func sessionIndexes() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            func indexed(_ table: String) throws -> Set<[String]> {
                let names = try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))")
                    .filter { ($0["origin"] as String) == "c" }.map { $0["name"] as String }
                return Set(try names.map { name in
                    try Row.fetchAll(db, sql: "PRAGMA index_info(\(name))").map { $0["name"] as String }
                })
            }
            let session = try indexed("fact_reading_session")
            #expect(session.contains(["book_id", "started_at"]))
            #expect(session.contains(["local_date"]))
            #expect(try indexed("fact_location_event").contains(["session_id"]))
        }
    }
}

@Suite struct SessionWriteTests {
    @Test func finishSessionInsertsRowAndDeletesDraft() async throws {
        let db = try AppDatabase.inMemory()
        try await db.saveCheckpoint(sampleDraft())
        #expect(try count(db, "session_draft") == 1)

        try await db.finishSession(sampleRow(), now: at(700))
        #expect(try count(db, "session_draft") == 0)
        let record = try #require(try await db.reader.read { db in try SessionRecord.fetchOne(db, key: "session-1") })
        #expect(record.startedAt == "2026-11-22T10:00:00.000Z")
        #expect(record.endedAt == "2026-11-22T10:10:00.000Z")
        #expect(record.createdAt == "2026-11-22T10:11:40.000Z")
        #expect(record.updatedAt == record.createdAt)
        #expect(record.endReason == "closed")
        #expect(record.activeSeconds == 540)
        #expect(record.wordsRead == 2500)
        #expect(record.isPaceEligible)
        #expect(!record.isUserEdited)
        #expect(record.deletedAt == nil)
        #expect(try count(db, "fact_reading_session", where: "is_pace_eligible = 1 AND is_user_edited = 0") == 1)

        // Idempotent.
        try await db.finishSession(sampleRow(), now: at(800))
        #expect(try count(db, "fact_reading_session") == 1)
    }

    @Test func lateCheckpointAfterFinishDoesNotResurrectDraft() async throws {
        let db = try AppDatabase.inMemory()
        try await db.finishSession(sampleRow(), now: at(700))
        try await db.saveCheckpoint(sampleDraft())
        #expect(try count(db, "session_draft") == 0)
    }

    @Test func saveCheckpointUpserts() async throws {
        let db = try AppDatabase.inMemory()
        try await db.saveCheckpoint(sampleDraft())
        var later = sampleDraft()
        later.lastCheckpointAt = at(60)
        try await db.saveCheckpoint(later)
        #expect(try count(db, "session_draft") == 1)
        #expect(try count(db, "session_draft", where: "last_checkpoint_at = '2026-11-22T10:01:00.000Z'") == 1)
    }

    @Test func discardSessionRemovesDraftAndEvents() async throws {
        let db = try AppDatabase.inMemory()
        let (_, outA) = drive([(0, .open(context)), (0, page(1000)), (10, page(1250))])
        let (_, outB) = drive([(0, .open(context)), (0, page(1000))])
        let rows = (outA + outB).compactMap { if case .locationEvent(let r) = $0 { r } else { nil } }
        try await db.appendLocationEvents(rows)
        let idA = rows[0].sessionID
        try await db.saveCheckpoint(sampleDraft(id: idA))
        #expect(try count(db, "fact_location_event") == 3)

        try await db.discardSession(id: idA)
        #expect(try count(db, "fact_location_event") == 1)
        #expect(try count(db, "fact_location_event", where: "session_id = '\(idA)'") == 0)
        #expect(try count(db, "session_draft") == 0)
    }

    @Test func locationEventMapping() async throws {
        let db = try AppDatabase.inMemory()
        let (_, out) = drive([(0, .open(context)), (0, page(1000)), (30, page(1250))])
        let rows = out.compactMap { if case .locationEvent(let r) = $0 { r } else { nil } }
        try await db.appendLocationEvents(rows)
        let records = try await db.reader.read { db in
            try LocationEventRecord.order(LocationEventRecord.Columns.occurredAt).fetchAll(db)
        }
        #expect(records.map(\.eventType) == ["open", "page_turn"])
        #expect(records[1].occurredAt == "2026-11-22T10:00:30.000Z")
        #expect(records[1].wordsDelta == 250)
        #expect(records[1].isCounted)
        #expect(records[1].secondsSincePrev == 30)
        #expect(try count(db, "fact_location_event", where: "is_counted = 1") == 1)
    }

    @Test func ensureDeviceIsInsertIfMissing() async throws {
        let db = try AppDatabase.inMemory()
        try await db.ensureDevice(id: "device-1", name: "Matt's iPhone", model: "iPhone17,1", now: at(0))
        try await db.ensureDevice(id: "device-1", name: "Renamed", model: "Other", now: at(100))
        let device = try #require(try await db.reader.read { db in try DeviceRecord.fetchOne(db, key: "device-1") })
        #expect(device.name == "Matt's iPhone")
        #expect(device.firstSeenAt == "2026-11-22T10:00:00.000Z")
        #expect(try count(db, "dim_device") == 1)
    }

    @Test func softDeleteHidesFromSessionRequests() async throws {
        let db = try AppDatabase.inMemory()
        try await db.finishSession(sampleRow(id: "s1"), now: at(700))
        var other = sampleRow(id: "s2")
        other.startedAt = at(1000)
        try await db.finishSession(other, now: at(1700))
        #expect(try await db.reader.read { db in try SessionRequests.sessions(bookID: "book-1").fetchAll(db) }
            .map(\.id) == ["s2", "s1"])

        try await db.softDeleteSession(id: "s1", now: at(2000))
        let visible = try await db.reader.read { db in try SessionRequests.sessions(bookID: "book-1").fetchAll(db) }
        #expect(visible.map(\.id) == ["s2"])
        let deleted = try #require(try await db.reader.read { db in try SessionRecord.fetchOne(db, key: "s1") })
        #expect(deleted.deletedAt == "2026-11-22T10:33:20.000Z")
        #expect(deleted.updatedAt == deleted.deletedAt)
    }
}

@Suite struct RecoverDraftsTests {
    @Test func recoverDraftsEndToEnd() async throws {
        let db = try AppDatabase.inMemory()

        // A: 90 s of reading, checkpointed at 120 → recovered.
        let (trackerA, outA) = drive([(0, .open(context)), (0, page(1000)), (30, page(1250)), (30, .tick),
                                      (60, page(1500)), (60, .tick), (90, page(1750)), (90, .tick), (120, .tick)])
        let idA = try #require(trackerA.currentSessionID)
        try await persist(outA, in: db)

        // B: 15 s, checkpointed at background → discarded with its events.
        let (trackerB, outB) = drive([(0, .open(context)), (0, page(5000)), (10, page(5250)), (15, .background)])
        let idB = try #require(trackerB.currentSessionID)
        try await persist(outB, in: db)

        // C: undecodable state → discarded, doesn't block the rest.
        try await db.saveCheckpoint(SessionDraft(sessionID: "garbage", bookID: "book-1", startedAt: at(0),
                                                 lastCheckpointAt: at(30), stateJSON: "{oops"))

        #expect(try count(db, "session_draft") == 3)
        #expect(try count(db, "fact_location_event", where: "session_id = '\(idB)'") > 0)

        let written = try await db.recoverDrafts(now: at(5000))
        #expect(written == 1)
        #expect(try count(db, "session_draft") == 0)
        #expect(try count(db, "fact_location_event", where: "session_id = '\(idB)'") == 0)
        #expect(try count(db, "fact_location_event", where: "session_id = '\(idA)'") == 4)
        #expect(try count(db, "fact_reading_session") == 1)

        let record = try #require(try await db.reader.read { db in try SessionRecord.fetchOne(db, key: idA) })
        #expect(record.endReason == "crash_recovered")
        #expect(record.endedAt == "2026-11-22T10:02:00.000Z")
        #expect(record.activeSeconds == 120)
        #expect(record.wordsRead == 750)
        #expect(record.deviceID == "device-1")
        #expect(record.localDate == "2026-11-22")

        // Running again is a no-op.
        #expect(try await db.recoverDrafts(now: at(6000)) == 0)
    }
}

@Suite struct TrackerConfigSettingsTests {
    @Test func defaultsWithoutSettings() async throws {
        let db = try AppDatabase.inMemory()
        let config = try await db.trackerConfig(timeZone: utc)
        #expect(config == TrackerConfig(timeZone: utc))
    }

    @Test func readsOverrides() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setSettingJSON("240", forKey: "idle_threshold_s")
        try await db.setSettingJSON("600.5", forKey: "session_gap_s")
        try await db.setSettingJSON("5", forKey: "day_start_hour")
        let config = try await db.trackerConfig(timeZone: utc)
        #expect(config.idleThreshold == 240)
        #expect(config.sessionGap == 600.5)
        #expect(config.dayStartHour == 5)
        #expect(config.timeZone == utc)
        #expect(config.minActiveSeconds == 30)
    }

    @Test func ignoresNonNumericValues() async throws {
        let db = try AppDatabase.inMemory()
        try await db.setSettingJSON("\"abc\"", forKey: "idle_threshold_s")
        try await db.setSettingJSON("null", forKey: "day_start_hour")
        let config = try await db.trackerConfig(timeZone: utc)
        #expect(config.idleThreshold == 180)
        #expect(config.dayStartHour == 4)
    }
}
