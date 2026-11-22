import Foundation
@preconcurrency import ReadiumNavigator

/// `EPUBPreferences` <-> JSON string, the only form in which reader preferences cross into
/// BookKit (`book.preferences_json`, `app_setting[default_preferences]`).
enum ReaderPreferences {
    /// Decodes stored preferences. `nil`, `""`, `"{}"` and anything unparseable all mean
    /// "no preferences", so a bad row never stops a book from opening.
    static func decode(_ json: String?) -> EPUBPreferences {
        guard
            let json,
            let data = json.data(using: .utf8),
            let prefs = try? JSONDecoder().decode(EPUBPreferences.self, from: data)
        else {
            return .empty
        }
        return prefs
    }

    /// Deterministic JSON (sorted keys). Falls back to `"{}"` if encoding fails.
    static func encode(_ prefs: EPUBPreferences) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(prefs),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    /// The preferences a book opens with: the book's own once it has any, else the app defaults.
    /// Not a merge: a nil field (e.g. font "Original") means "unset" to `merging(_:)`, so a
    /// merge would bring a default font back. The first edit saves the full set (defaults
    /// included) to the book, so later default changes only affect untouched books.
    static func initial(bookJSON: String?, defaultsJSON: String?) -> EPUBPreferences {
        let book = decode(bookJSON)
        return encode(book) == "{}" ? decode(defaultsJSON) : book
    }

    /// JSON for "use as default for new books": drops the publication-specific fields
    /// (language, reading progression, spread, vertical text, offset first page).
    static func sharedJSON(_ prefs: EPUBPreferences) -> String {
        encode(prefs.filterSharedPreferences())
    }
}
