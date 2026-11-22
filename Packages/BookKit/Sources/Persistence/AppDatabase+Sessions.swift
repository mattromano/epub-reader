import Foundation
import GRDB
import Tracking

// SCAFFOLD STUBS — Agent B implements. Signatures are the contract.
extension AppDatabase {
    /// Inserts the dim_device row if missing.
    public func ensureDevice(id: String, name: String, model: String, now: Date = Date()) async throws {}

    public func appendLocationEvents(_ rows: [LocationEventRow]) async throws {}

    /// Upserts session_draft. No-op if fact_reading_session already has this session_id.
    public func saveCheckpoint(_ draft: SessionDraft) async throws {}

    /// Inserts fact_reading_session and deletes its draft, in one transaction.
    public func finishSession(_ row: SessionRow, now: Date = Date()) async throws {}

    /// Deletes the draft and the session's location events.
    public func discardSession(id: String) async throws {}

    /// Finalizes every session_draft via `SessionTracker.recover` (crash_recovered), or discards
    /// it; deletes the drafts. Returns the number of sessions written.
    @discardableResult
    public func recoverDrafts(now: Date = Date()) async throws -> Int { 0 }

    /// Soft delete (sets deleted_at, updated_at).
    public func softDeleteSession(id: String, now: Date = Date()) async throws {}

    /// Tracker thresholds from app_setting (idle_threshold_s, session_gap_s, day_start_hour),
    /// falling back to SPEC defaults.
    public func trackerConfig(timeZone: TimeZone = .current) async throws -> TrackerConfig { TrackerConfig(timeZone: timeZone) }
}
