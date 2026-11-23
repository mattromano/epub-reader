import GRDB

extension Migrations {
    /// v4_highlights: `fact_highlight` ✓, `dim_tag` ✓, `bridge_highlight_tag` ✓, `fact_bookmark` ✓
    /// (SPEC §5.2). M3 scaffold: Agent A writes the body.
    static func v4Highlights(_ db: Database) throws {}
}
