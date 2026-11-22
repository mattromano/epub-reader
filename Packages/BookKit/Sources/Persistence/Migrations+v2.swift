import GRDB

/// Namespace for migration bodies registered in `AppDatabase.migrator`.
enum Migrations {}

extension Migrations {
    /// v2_chapters_index: `dim_chapter`, `dim_word_anchor` (SPEC §5.2).
    /// Local, rebuildable, never synced, so the UNIQUE index on anchors is allowed.
    static func v2ChaptersIndex(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE dim_chapter (
                chapter_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT NOT NULL REFERENCES dim_book(book_id) ON DELETE CASCADE,
                spine_index INTEGER,
                href TEXT,
                title TEXT,
                is_linear INTEGER DEFAULT 1,
                word_count INTEGER DEFAULT 0,
                char_count INTEGER DEFAULT 0,
                cum_words_start INTEGER DEFAULT 0,
                text_hash TEXT
            );
            CREATE INDEX idx_dim_chapter_book_spine ON dim_chapter (book_id, spine_index);

            CREATE TABLE dim_word_anchor (
                anchor_id TEXT PRIMARY KEY NOT NULL,
                book_id TEXT NOT NULL,
                chapter_id TEXT NOT NULL REFERENCES dim_chapter(chapter_id) ON DELETE CASCADE,
                block_index INTEGER,
                progression REAL,
                char_offset INTEGER,
                cum_word_offset INTEGER
            );
            CREATE UNIQUE INDEX idx_dim_word_anchor_chapter_block ON dim_word_anchor (chapter_id, block_index);
            """)
    }
}
