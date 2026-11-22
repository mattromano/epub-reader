import GRDB

/// Namespace for migration bodies registered in `AppDatabase.migrator`.
enum Migrations {}

extension Migrations {
    /// v2_chapters_index: `dim_chapter`, `dim_word_anchor` (SPEC §5.2, local tables).
    /// SCAFFOLD STUB — Agent A implements.
    static func v2ChaptersIndex(_ db: Database) throws {}
}
