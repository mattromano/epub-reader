import Foundation
import NaturalLanguage
import CryptoKit

/// Finds a Readium text quote in our normalized chapter text (SPEC §7, step 1).
///
/// Readium's quote comes from the DOM: `highlight` is `selection.toString()` (newlines between
/// blocks), `before`/`after` are slices of `document.body.textContent` (adjacent blocks may have
/// no whitespace at all). `TextNormalizer` puts one space at every block boundary. So matching
/// ignores whitespace and soft hyphens entirely, on both sides, and maps the hit back to
/// `Character` offsets in the normalized text.
public enum QuoteLocator {
    /// `[char_start, char_end)` of `quote` in `text`, in `Character` offsets; nil if the quote
    /// (ignoring whitespace) doesn't occur. Among several occurrences, the one whose surroundings
    /// best match `prefix` (text right before) and `suffix` (text right after) wins; ties go to
    /// the occurrence nearest `progressionHint` (0–1 through `text`), then the first.
    public static func locate(quote: String, prefix: String, suffix: String, in text: String,
                              progressionHint: Double? = nil) -> Range<Int>? {
        locateImpl(quote: quote, prefix: prefix, suffix: suffix, in: text, progressionHint: progressionHint)
    }
}

public enum WordCounter {
    /// Words in `text`, counted with `NLTokenizer(unit: .word)` like the word index.
    public static func count(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }
}

extension TextNormalizer {
    /// sha256 hex of normalized text; equals `dim_chapter.text_hash` for the same chapter.
    public static func textHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
