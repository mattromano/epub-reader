import GRDB

extension Migrations {
    /// v7_readwise (M7): local-only `readwise_highlight` maps a highlight to its Readwise id, so
    /// note and color edits can be PATCHed (a re-POST with unchanged text is deduped and ignored).
    ///
    /// Local-only and rebuildable: the push re-derives ids from Readwise by `highlight_url`. Not a
    /// column on `fact_highlight`, so the synced table's schema doesn't change.
    static func v7Readwise(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE readwise_highlight (
                highlight_id TEXT PRIMARY KEY NOT NULL,
                readwise_highlight_id INTEGER NOT NULL,
                updated_at TEXT NOT NULL
            );
            """)
    }
}
