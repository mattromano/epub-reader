import GRDB

extension Migrations {
    /// v5_highlight_search: `fts_highlight` (SPEC §5.2 note under `fact_highlight`, PLAN M4).
    ///
    /// Local-only and rebuildable: an FTS5 table over quote, note, book title and authors, one row
    /// per non-deleted highlight, keyed by an UNINDEXED `highlight_id`. Triggers on `fact_highlight`
    /// (insert, update, delete) and on `dim_book` (insert, for highlights synced before their book,
    /// and title/authors update) keep it in sync; the
    /// migration backfills existing highlights. Tokenizer `unicode61 remove_diacritics 2`, with a
    /// prefix index for 2- and 3-character prefixes (search-as-you-type).
    static func v5HighlightSearch(_ db: Database) throws {
        try db.execute(sql: """
            CREATE VIRTUAL TABLE fts_highlight USING fts5(
                highlight_id UNINDEXED,
                quote_exact,
                note,
                title,
                authors,
                tokenize = 'unicode61 remove_diacritics 2',
                prefix = '2 3'
            );

            CREATE TRIGGER fts_highlight_after_insert AFTER INSERT ON fact_highlight
            WHEN NEW.deleted_at IS NULL
            BEGIN
                INSERT INTO fts_highlight (highlight_id, quote_exact, note, title, authors)
                SELECT NEW.highlight_id, NEW.quote_exact, COALESCE(NEW.note, ''),
                       COALESCE(b.title, ''), COALESCE(b.authors, '')
                FROM (SELECT 1) AS one
                LEFT JOIN dim_book AS b ON b.book_id = NEW.book_id;
            END;

            CREATE TRIGGER fts_highlight_after_update AFTER UPDATE ON fact_highlight
            BEGIN
                DELETE FROM fts_highlight WHERE highlight_id = OLD.highlight_id;
                INSERT INTO fts_highlight (highlight_id, quote_exact, note, title, authors)
                SELECT NEW.highlight_id, NEW.quote_exact, COALESCE(NEW.note, ''),
                       COALESCE(b.title, ''), COALESCE(b.authors, '')
                FROM (SELECT 1) AS one
                LEFT JOIN dim_book AS b ON b.book_id = NEW.book_id
                WHERE NEW.deleted_at IS NULL;
            END;

            CREATE TRIGGER fts_highlight_after_delete AFTER DELETE ON fact_highlight
            BEGIN
                DELETE FROM fts_highlight WHERE highlight_id = OLD.highlight_id;
            END;

            CREATE TRIGGER fts_highlight_after_book_update AFTER UPDATE OF title, authors ON dim_book
            BEGIN
                DELETE FROM fts_highlight
                WHERE highlight_id IN (SELECT highlight_id FROM fact_highlight WHERE book_id = NEW.book_id);
                INSERT INTO fts_highlight (highlight_id, quote_exact, note, title, authors)
                SELECT h.highlight_id, h.quote_exact, COALESCE(h.note, ''),
                       COALESCE(NEW.title, ''), COALESCE(NEW.authors, '')
                FROM fact_highlight AS h
                WHERE h.book_id = NEW.book_id AND h.deleted_at IS NULL;
            END;

            CREATE TRIGGER fts_highlight_after_book_insert AFTER INSERT ON dim_book
            BEGIN
                DELETE FROM fts_highlight
                WHERE highlight_id IN (SELECT highlight_id FROM fact_highlight WHERE book_id = NEW.book_id);
                INSERT INTO fts_highlight (highlight_id, quote_exact, note, title, authors)
                SELECT h.highlight_id, h.quote_exact, COALESCE(h.note, ''),
                       COALESCE(NEW.title, ''), COALESCE(NEW.authors, '')
                FROM fact_highlight AS h
                WHERE h.book_id = NEW.book_id AND h.deleted_at IS NULL;
            END;

            INSERT INTO fts_highlight (highlight_id, quote_exact, note, title, authors)
            SELECT h.highlight_id, h.quote_exact, COALESCE(h.note, ''),
                   COALESCE(b.title, ''), COALESCE(b.authors, '')
            FROM fact_highlight AS h
            LEFT JOIN dim_book AS b ON b.book_id = h.book_id
            WHERE h.deleted_at IS NULL;
            """)
    }
}
