import GRDB

extension Migrations {
    /// v3_sessions: `fact_reading_session` ✓, `fact_location_event`, `session_draft`, `dim_device` ✓
    /// (SPEC §5.2).
    ///
    /// Synced tables (✓): one TEXT UUID PK, no other UNIQUE constraint, every other column
    /// nullable or DEFAULT. No declared FKs on the synced fact (an FK to `dim_device` could reject
    /// a finished session if the device row is missing; sync can also deliver rows out of order);
    /// the references are indexed instead.
    ///
    /// Local tables: no FK to `fact_reading_session` (the session row is written only at session
    /// end); `session_id` is indexed instead.
    static func v3Sessions(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dim_device (
                device_id TEXT PRIMARY KEY NOT NULL,
                name TEXT,
                model TEXT,
                first_seen_at TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );

            CREATE TABLE fact_reading_session (
                session_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT,
                device_id TEXT,
                started_at TEXT,
                ended_at TEXT,
                local_date TEXT,
                local_start_hour INTEGER,
                tz_offset_minutes INTEGER,
                wall_seconds REAL NOT NULL DEFAULT 0,
                active_seconds REAL NOT NULL DEFAULT 0,
                start_word_idx INTEGER,
                end_word_idx INTEGER,
                words_read INTEGER NOT NULL DEFAULT 0,
                start_total_progression REAL,
                end_total_progression REAL,
                start_locator_json TEXT,
                end_locator_json TEXT,
                page_turns INTEGER NOT NULL DEFAULT 0,
                jump_count INTEGER NOT NULL DEFAULT 0,
                reading_mode TEXT,
                font_size REAL,
                end_reason TEXT,
                is_pace_eligible INTEGER NOT NULL DEFAULT 1,
                is_user_edited INTEGER NOT NULL DEFAULT 0,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_fact_reading_session_book_started ON fact_reading_session (book_id, started_at);
            CREATE INDEX idx_fact_reading_session_local_date ON fact_reading_session (local_date);
            CREATE INDEX idx_fact_reading_session_device ON fact_reading_session (device_id);

            CREATE TABLE fact_location_event (
                event_id TEXT PRIMARY KEY NOT NULL,
                session_id TEXT,
                book_id TEXT,
                occurred_at TEXT,
                event_type TEXT,
                chapter_id TEXT,
                progression REAL,
                total_progression REAL,
                word_idx INTEGER,
                words_delta INTEGER,
                seconds_since_prev REAL,
                is_counted INTEGER NOT NULL DEFAULT 0,
                locator_json TEXT
            );
            CREATE INDEX idx_fact_location_event_session ON fact_location_event (session_id);
            CREATE INDEX idx_fact_location_event_book_occurred ON fact_location_event (book_id, occurred_at);

            CREATE TABLE session_draft (
                session_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT,
                started_at TEXT,
                last_checkpoint_at TEXT,
                state_json TEXT
            );
            """)
    }
}
