import Foundation
import GRDB
import Importing

/// A highlight whose chapter text changed since it was anchored (SPEC §7, step 3).
public struct StaleAnchor: Sendable, Equatable {
    public var highlight: HighlightRecord
    /// `dim_chapter.href` of the highlight's chapter, to load the current text.
    public var chapterHref: String
    /// `dim_chapter.text_hash` of the current file.
    public var currentTextHash: String
}

/// Outcome of re-anchoring one highlight against the current chapter text.
public enum AnchorOutcome: Sendable, Equatable {
    /// The exact quote was found at `[charStart, charEnd)`.
    case exact(charStart: Int, charEnd: Int)
    /// Not found. M4.5 adds a fuzzy match before giving up.
    case orphaned
}

public enum HighlightAnchoring {
    /// Re-anchors `highlight` in `chapterText` (normalized, like `dim_chapter`): an exact quote
    /// search with prefix/suffix scoring, hinted by the stored `char_start`.
    public static func reanchor(_ highlight: HighlightRecord, in chapterText: String) -> AnchorOutcome {
        let length = chapterText.count
        let hint: Double? = {
            guard let start = highlight.charStart, length > 0 else { return highlight.progression }
            return min(1, max(0, Double(start) / Double(length)))
        }()
        guard let range = QuoteLocator.locate(
            quote: highlight.quoteExact, prefix: highlight.quotePrefix ?? "",
            suffix: highlight.quoteSuffix ?? "", in: chapterText, progressionHint: hint
        ) else { return .orphaned }
        return .exact(charStart: range.lowerBound, charEnd: range.upperBound)
    }
}

extension AppDatabase {
    /// Non-deleted highlights of `bookID` whose `chapter_text_hash` differs from the indexed
    /// chapter's `text_hash` (joined on `chapter_id`). Highlights with no stored hash, or whose
    /// chapter isn't indexed, are skipped: there's nothing to compare.
    public func staleAnchors(bookID: String) async throws -> [StaleAnchor] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                WITH current_chapter AS (
                    SELECT chapter_id, href, text_hash
                    FROM dim_chapter
                    WHERE book_id = :book_id
                )
                SELECT h.*, c.href AS current_href, c.text_hash AS current_text_hash
                FROM fact_highlight AS h
                JOIN current_chapter AS c ON c.chapter_id = h.chapter_id
                WHERE h.book_id = :book_id
                  AND h.deleted_at IS NULL
                  AND h.chapter_text_hash IS NOT NULL
                  AND c.text_hash IS NOT NULL
                  AND h.chapter_text_hash <> c.text_hash
                ORDER BY h.total_progression, h.created_at
                """, arguments: ["book_id": bookID])
            return try rows.map { row in
                StaleAnchor(highlight: try HighlightRecord(row: row),
                            chapterHref: row["current_href"], currentTextHash: row["current_text_hash"])
            }
        }
    }

    /// Records a re-anchor: sets `chapter_text_hash` to `textHash` (so it isn't retried on every
    /// open), `anchor_status`, `last_anchored_at` and, when found, `char_start`/`char_end`.
    /// An orphan keeps its old offsets and stays visible. Bumps `updated_at`. No-op on a deleted row.
    public func applyAnchor(id: String, outcome: AnchorOutcome, textHash: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        let (status, start, end): (AnchorStatus, Int?, Int?) = switch outcome {
        case let .exact(charStart, charEnd): (.exact, charStart, charEnd)
        case .orphaned: (.orphaned, nil, nil)
        }
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE fact_highlight
                    SET chapter_text_hash = :hash,
                        anchor_status = :status,
                        anchor_score = NULL,
                        char_start = COALESCE(:start, char_start),
                        char_end = COALESCE(:end, char_end),
                        last_anchored_at = :now,
                        updated_at = :now
                    WHERE highlight_id = :id AND deleted_at IS NULL
                    """,
                arguments: ["hash": textHash, "status": status.rawValue, "start": start, "end": end,
                            "now": nowString, "id": id])
        }
    }
}
