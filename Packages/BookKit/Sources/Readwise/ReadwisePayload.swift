import Foundation
import Persistence

/// One highlight in `POST /api/v2/highlights/` ([api_deets](https://readwise.io/api_deets)).
public struct ReadwiseCreateHighlight: Encodable, Sendable, Equatable {
    public var text: String
    public var title: String
    public var author: String?
    public var category = "books"
    public var note: String?
    /// Book word index of the highlight's start, so Readwise sorts in reading order.
    public var location: Int?
    public var locationType = "order"
    public var highlightedAt: String?
    /// `margins://highlight/<uuid>`: unique per highlight; how ids are matched back.
    public var highlightURL: String
    public var sourceType = ReadwisePayload.sourceType

    enum CodingKeys: String, CodingKey {
        case text, title, author, category, note, location
        case locationType = "location_type"
        case highlightedAt = "highlighted_at"
        case highlightURL = "highlight_url"
        case sourceType = "source_type"
    }
}

/// `PATCH /api/v2/highlights/<id>/`. A re-POST with unchanged text is deduped and ignored, so
/// note and color edits go through here.
public struct ReadwiseUpdateHighlight: Encodable, Sendable, Equatable {
    public var text: String
    public var note: String
    public var color: String
}

/// Maps a pending highlight to Readwise requests.
public enum ReadwisePayload {
    public static let sourceType = "margins"
    static let urlPrefix = "margins://highlight/"
    static let maxText = 8191
    static let maxNote = 8191
    static let maxTitle = 511
    static let maxAuthor = 1024

    public static func highlightURL(_ highlightID: String) -> String { urlPrefix + highlightID }

    /// The highlight id in a `margins://highlight/<uuid>` URL, nil for anything else.
    public static func highlightID(fromURL url: String?) -> String? {
        guard let url, url.hasPrefix(urlPrefix) else { return nil }
        let id = String(url.dropFirst(urlPrefix.count))
        return id.isEmpty ? nil : id
    }

    public static func create(_ highlight: ReadwisePendingHighlight) -> ReadwiseCreateHighlight {
        let title = clip(highlight.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines), maxTitle)
        let author = clip(highlight.bookAuthors.trimmingCharacters(in: .whitespacesAndNewlines), maxAuthor)
        return ReadwiseCreateHighlight(
            text: clip(text(highlight), maxText),
            title: title.isEmpty ? "Untitled" : title,
            author: author.isEmpty ? nil : author,
            note: createNote(highlight),
            location: highlight.wordIdx,
            highlightedAt: highlight.createdAt,
            highlightURL: highlightURL(highlight.highlightID))
    }

    public static func update(_ highlight: ReadwisePendingHighlight) -> ReadwiseUpdateHighlight {
        ReadwiseUpdateHighlight(
            text: clip(text(highlight), maxText),
            note: clip(highlight.note.trimmingCharacters(in: .whitespacesAndNewlines), maxNote),
            color: HighlightColor(rawValue: highlight.color ?? "")?.rawValue ?? HighlightColor.yellow.rawValue)
    }

    private static func text(_ highlight: ReadwisePendingHighlight) -> String {
        highlight.quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Readwise inline tagging: a first line of `.tag` tokens, then the note on the next line
    /// ([blog](https://blog.readwise.io/tag-your-highlights-while-you-read/)). nil when empty.
    static func createNote(_ highlight: ReadwisePendingHighlight) -> String? {
        let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = tagLine(highlight.tags)
        let combined = [tags, note].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? nil : clip(combined, maxNote)
    }

    /// `.tag` tokens separated by spaces. A tag is one word: whitespace becomes `-`, characters
    /// other than letters, digits, `_` and `-` are dropped. Deduped case-insensitively.
    static func tagLine(_ names: [String]) -> String {
        var seen = Set<String>()
        var tokens: [String] = []
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        for name in names {
            let dashed = name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                .joined(separator: "-")
            let cleaned = String(String.UnicodeScalarView(dashed.unicodeScalars.filter { allowed.contains($0) }))
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { continue }
            tokens.append("." + cleaned)
        }
        return tokens.joined(separator: " ")
    }

    /// At most `max` UTF-16 units (Readwise's limits are string lengths), cut on a Character boundary.
    static func clip(_ string: String, _ max: Int) -> String {
        guard string.utf16.count > max else { return string }
        var result = ""
        var count = 0
        for character in string {
            let size = character.utf16.count
            if count + size > max { break }
            result.append(character)
            count += size
        }
        return result
    }
}

// MARK: - Responses

/// A book in the create response; `modified_highlights` lists the ids the request touched.
public struct ReadwiseBook: Decodable, Sendable, Equatable {
    public var id: Int
    public var modifiedHighlights: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case modifiedHighlights = "modified_highlights"
    }
}

/// A highlight in `GET /api/v2/highlights/`. `url` is the `highlight_url` it was created with.
public struct ReadwiseListedHighlight: Decodable, Sendable, Equatable {
    public var id: Int
    public var url: String?
}

struct ReadwiseHighlightPage: Decodable {
    var next: String?
    var results: [ReadwiseListedHighlight]
}
