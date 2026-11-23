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
    /// No exact hit, but an approximate one scored ≥ `FuzzyQuoteMatcher.acceptThreshold` (M4.5).
    /// `progression` is `charStart / chapter length`; `locatorJSON` is the stored locator with its
    /// `text` and `locations.progression` moved to the match (nil if it couldn't be parsed).
    case fuzzy(charStart: Int, charEnd: Int, score: Double, progression: Double, locatorJSON: String?)
    /// Neither an exact nor an acceptable fuzzy match.
    case orphaned
}

public enum HighlightAnchoring {
    /// Re-anchors `highlight` in `chapterText` (normalized, like `dim_chapter`): an exact quote
    /// search with prefix/suffix scoring, then a fuzzy match (M4.5), both hinted by the stored
    /// `char_start` (else `progression`).
    public static func reanchor(_ highlight: HighlightRecord, in chapterText: String) -> AnchorOutcome {
        let length = chapterText.count
        let hint: Double? = {
            guard let start = highlight.charStart, length > 0 else { return highlight.progression }
            return min(1, max(0, Double(start) / Double(length)))
        }()
        let prefix = highlight.quotePrefix ?? ""
        let suffix = highlight.quoteSuffix ?? ""
        if let range = QuoteLocator.locate(quote: highlight.quoteExact, prefix: prefix, suffix: suffix,
                                           in: chapterText, progressionHint: hint) {
            return .exact(charStart: range.lowerBound, charEnd: range.upperBound)
        }
        guard let match = FuzzyQuoteMatcher.match(quote: highlight.quoteExact, prefix: prefix, suffix: suffix,
                                                  in: chapterText, progressionHint: hint),
              match.score >= FuzzyQuoteMatcher.acceptThreshold else { return .orphaned }

        let chars = Array(chapterText)
        let range = match.range
        let progression = Double(range.lowerBound) / Double(length)
        let beforeCount = prefix.isEmpty ? 32 : prefix.count
        let afterCount = suffix.isEmpty ? 32 : suffix.count
        let json = highlight.locatorJSON.flatMap {
            rewriteLocator($0,
                           highlight: String(chars[range]),
                           before: String(chars[max(0, range.lowerBound - beforeCount)..<range.lowerBound]),
                           after: String(chars[range.upperBound..<min(chars.count, range.upperBound + afterCount)]),
                           progression: progression)
        }
        return .fuzzy(charStart: range.lowerBound, charEnd: range.upperBound, score: match.score,
                      progression: progression, locatorJSON: json)
    }

    /// Moves a stored Readium locator to a new quote: replaces `text.highlight/before/after` and
    /// `locations.progression`, keeping every other key. Readium re-anchors decorations from the
    /// text quote, so this is what makes the highlight render at its new place. Nil if `json`
    /// isn't a JSON object.
    static func rewriteLocator(_ json: String, highlight: String, before: String, after: String,
                               progression: Double) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return nil
        }
        var text = object["text"] as? [String: Any] ?? [:]
        text["highlight"] = highlight
        text["before"] = before
        text["after"] = after
        object["text"] = text
        var locations = object["locations"] as? [String: Any] ?? [:]
        locations["progression"] = progression
        object["locations"] = locations
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
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
    /// A fuzzy hit also stores `anchor_score`, `progression` and the rewritten `locator_json`.
    /// An orphan keeps its old offsets and stays visible. Bumps `updated_at`. No-op on a deleted row.
    public func applyAnchor(id: String, outcome: AnchorOutcome, textHash: String, now: Date = Date()) async throws {
        let nowString = Timestamp.string(from: now)
        typealias Columns = (status: AnchorStatus, start: Int?, end: Int?, score: Double?,
                             progression: Double?, locator: String?)
        let c: Columns = switch outcome {
        case let .exact(charStart, charEnd): (.exact, charStart, charEnd, nil, nil, nil)
        case let .fuzzy(charStart, charEnd, score, progression, locator):
            (.fuzzy, charStart, charEnd, score, progression, locator)
        case .orphaned: (.orphaned, nil, nil, nil, nil, nil)
        }
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE fact_highlight
                    SET chapter_text_hash = :hash,
                        anchor_status = :status,
                        anchor_score = :score,
                        char_start = COALESCE(:start, char_start),
                        char_end = COALESCE(:end, char_end),
                        progression = COALESCE(:progression, progression),
                        locator_json = COALESCE(:locator, locator_json),
                        last_anchored_at = :now,
                        updated_at = :now
                    WHERE highlight_id = :id AND deleted_at IS NULL
                    """,
                arguments: ["hash": textHash, "status": c.status.rawValue, "start": c.start, "end": c.end,
                            "score": c.score, "progression": c.progression, "locator": c.locator,
                            "now": nowString, "id": id])
        }
    }
}
