import GRDB

extension Migrations {
    /// v4_highlights: `fact_highlight` ✓, `dim_tag` ✓, `bridge_highlight_tag` ✓, `fact_bookmark` ✓
    /// (SPEC §5.2).
    ///
    /// All four are synced: one TEXT UUID PK, no other UNIQUE constraint, every other column
    /// nullable or DEFAULT, no declared FKs (sync can deliver rows out of order). Tag names and
    /// `(highlight_id, tag_id)` pairs are deduped in code; the references are indexed instead.
    /// FTS for highlights arrives in M4.
    static func v4Highlights(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE fact_highlight (
                highlight_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT,
                chapter_id TEXT,
                spine_href TEXT,
                chapter_title TEXT,
                quote_exact TEXT NOT NULL DEFAULT '',
                quote_prefix TEXT DEFAULT '',
                quote_suffix TEXT DEFAULT '',
                char_start INTEGER,
                char_end INTEGER,
                word_idx INTEGER,
                word_count INTEGER,
                progression REAL,
                total_progression REAL,
                position INTEGER,
                css_selector TEXT,
                partial_cfi TEXT,
                dom_range_json TEXT,
                locator_json TEXT,
                readium_version TEXT,
                chapter_text_hash TEXT,
                anchor_status TEXT DEFAULT 'exact',
                anchor_score REAL,
                last_anchored_at TEXT,
                color TEXT DEFAULT 'yellow',
                note TEXT DEFAULT '',
                style TEXT DEFAULT 'highlight',
                export_readwise_at TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_fact_highlight_book_progression ON fact_highlight (book_id, total_progression);

            CREATE TABLE dim_tag (
                tag_id TEXT PRIMARY KEY NOT NULL,
                name TEXT,
                color TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_dim_tag_name ON dim_tag (name);

            CREATE TABLE bridge_highlight_tag (
                bridge_id TEXT PRIMARY KEY NOT NULL,
                highlight_id TEXT,
                tag_id TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_bridge_highlight_tag_pair ON bridge_highlight_tag (highlight_id, tag_id);
            CREATE INDEX idx_bridge_highlight_tag_tag ON bridge_highlight_tag (tag_id);

            CREATE TABLE fact_bookmark (
                bookmark_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT,
                spine_href TEXT,
                progression REAL,
                locator_json TEXT,
                total_progression REAL,
                label TEXT,
                created_at TEXT,
                updated_at TEXT,
                deleted_at TEXT
            );
            CREATE INDEX idx_fact_bookmark_book_progression ON fact_bookmark (book_id, total_progression);
            """)
    }
}
