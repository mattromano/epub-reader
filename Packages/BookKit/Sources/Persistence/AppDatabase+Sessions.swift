import Foundation
import GRDB
import Tracking

// Session tracking writes (SPEC §5.2, §6.1). Each method is one write transaction.
extension AppDatabase {
    /// Inserts the dim_device row if missing.
    public func ensureDevice(id: String, name: String, model: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            guard try DeviceRecord.fetchOne(db, key: id) == nil else { return }
            try DeviceRecord(id: id, name: name, model: model, firstSeenAt: nowString,
                             createdAt: nowString, updatedAt: nowString, deletedAt: nil).insert(db)
        }
    }

    public func appendLocationEvents(_ rows: [LocationEventRow]) async throws {
        guard !rows.isEmpty else { return }
        try await writer.write { db in
            for row in rows {
                try LocationEventRecord(row).insert(db, onConflict: .ignore)
            }
        }
    }

    /// Upserts session_draft. No-op if fact_reading_session already has this session_id.
    public func saveCheckpoint(_ draft: SessionDraft) async throws {
        try await writer.write { db in
            guard try !SessionRecord.exists(db, key: draft.sessionID) else { return }
            try SessionDraftRecord(draft).upsert(db)
        }
    }

    /// Inserts fact_reading_session and deletes its draft, in one transaction, refreshing the
    /// session's day and book aggregates in the same transaction.
    /// Idempotent: if the session row already exists it is left as is.
    /// `timeZone` buckets highlights into reading days during the aggregate refresh.
    public func finishSession(_ row: SessionRow, now: Date = Date(), timeZone: TimeZone = .current) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            if try !SessionRecord.exists(db, key: row.sessionID) {
                try SessionRecord(row, now: nowString).insert(db)
                try Self.refreshAggregates(db, localDates: [row.localDate], bookIDs: [row.bookID],
                                           timeZone: timeZone)
            }
            _ = try SessionDraftRecord.deleteOne(db, key: row.sessionID)
        }
    }

    /// Deletes the draft and the session's location events.
    public func discardSession(id: String) async throws {
        try await writer.write { db in
            try Self.deleteDraftAndEvents(db, sessionID: id)
        }
    }

    /// Finalizes every session_draft via `SessionTracker.recover` (crash_recovered), or discards
    /// it; deletes the drafts. Returns the number of sessions written. Refreshes the recovered
    /// sessions' days and books once, in the same transaction.
    @discardableResult
    public func recoverDrafts(now: Date = Date(), timeZone: TimeZone = .current) async throws -> Int {
        let nowString = Timestamp.string(from: now)
        return try await writer.write { db in
            var written = 0
            var days: Set<String> = []
            var books: Set<String> = []
            for record in try SessionDraftRecord.fetchAll(db) {
                if try SessionRecord.exists(db, key: record.id) {
                    // Finished already; the draft is a leftover.
                    _ = try record.delete(db)
                    continue
                }
                // An undecodable draft is discarded rather than thrown, so it can't block launch.
                if let draft = record.draft, let row = SessionTracker.recover(draft) {
                    try SessionRecord(row, now: nowString).insert(db)
                    _ = try record.delete(db)
                    written += 1
                    days.insert(row.localDate)
                    books.insert(row.bookID)
                } else {
                    try Self.deleteDraftAndEvents(db, sessionID: record.id)
                }
            }
            try Self.refreshAggregates(db, localDates: days, bookIDs: books, timeZone: timeZone)
            return written
        }
    }

    /// Soft delete (sets deleted_at, updated_at) and refreshes the session's day and book
    /// aggregates in the same transaction.
    public func softDeleteSession(id: String, now: Date = Date(), timeZone: TimeZone = .current) async throws {
        let nowString = Timestamp.string(from: now)
        try await writer.write { db in
            guard let session = try SessionRecord
                .filter(SessionRecord.Columns.id == id)
                .filter(SessionRecord.Columns.deletedAt == nil)
                .fetchOne(db) else { return }
            try db.execute(
                sql: """
                    UPDATE fact_reading_session
                    SET deleted_at = ?, updated_at = ?
                    WHERE session_id = ? AND deleted_at IS NULL
                    """,
                arguments: [nowString, nowString, id])
            try Self.refreshAggregates(db, localDates: Set([session.localDate].compactMap { $0 }),
                                       bookIDs: Set([session.bookID].compactMap { $0 }), timeZone: timeZone)
        }
    }

    /// Tracker thresholds from app_setting (idle_threshold_s, session_gap_s, day_start_hour),
    /// falling back to SPEC defaults.
    public func trackerConfig(timeZone: TimeZone = .current) async throws -> TrackerConfig {
        var config = TrackerConfig(timeZone: timeZone)
        if let idle = try await settingNumber(forKey: "idle_threshold_s"), idle > 0 {
            config.idleThreshold = idle
        }
        if let gap = try await settingNumber(forKey: "session_gap_s"), gap > 0 {
            config.sessionGap = gap
        }
        if let hour = try await settingNumber(forKey: "day_start_hour"), (0...23).contains(hour),
           hour == hour.rounded() {
            config.dayStartHour = Int(hour)
        }
        return config
    }

    /// The setting's `value_json` as a JSON number; nil if missing or not a number.
    private func settingNumber(forKey key: String) async throws -> Double? {
        guard let json = try await settingJSON(forKey: key), let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Double.self, from: data)
    }

    private static func deleteDraftAndEvents(_ db: Database, sessionID: String) throws {
        _ = try SessionDraftRecord.deleteOne(db, key: sessionID)
        _ = try LocationEventRecord
            .filter(LocationEventRecord.Columns.sessionID == sessionID)
            .deleteAll(db)
    }
}
