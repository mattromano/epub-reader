import Foundation
import Importing
import Persistence
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

/// Readium selection → `NewHighlight` and `HighlightRecord` → `Decoration` (SPEC §7).
/// The only place highlight anchors cross between Readium and BookKit.
enum HighlightCapture {
    static let decorationGroup = "highlights"
    /// Locator format version stored with each highlight (`readium_version`).
    static let readiumVersion = "3.11"

    /// Builds the row for a selection. `locator_json` is the selection locator unmodified
    /// (Readium re-anchors decorations from its own text); the quote columns come from the
    /// sanitized text. `chapterText` is our normalized text of the selection's resource, if it
    /// could be read; without it the char range and text hash stay NULL.
    static func newHighlight(
        bookID: String,
        locator: Locator,
        chapterText: String?,
        wordIndex: WordIndex?,
        color: HighlightColor,
        style: HighlightStyle = .highlight
    ) -> NewHighlight? {
        guard let locatorJSON = locator.storedJSONString else { return nil }
        let text = locator.text.sanitized()
        let quote = text.highlight ?? ""
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let prefix = text.before ?? ""
        let suffix = text.after ?? ""

        let href = HrefKey.key(locator.href)
        let progression = locator.locations.progression
        var range: Range<Int>?
        var textHash: String?
        if let chapterText {
            range = QuoteLocator.locate(quote: quote, prefix: prefix, suffix: suffix,
                                        in: chapterText, progressionHint: progression)
            textHash = TextNormalizer.textHash(chapterText)
        }

        return NewHighlight(
            bookID: bookID,
            chapterID: wordIndex?.chapterID(href: href),
            spineHref: href,
            chapterTitle: locator.title ?? wordIndex?.chapters.first(where: { $0.href == href })?.title,
            quoteExact: quote,
            quotePrefix: prefix,
            quoteSuffix: suffix,
            charStart: range?.lowerBound,
            charEnd: range?.upperBound,
            wordIdx: wordIndex?.wordIdx(href: href, progression: progression ?? 0),
            wordCount: WordCounter.count(quote),
            progression: progression,
            totalProgression: locator.locations.totalProgression,
            position: locator.locations.position,
            cssSelector: locator.locations.cssSelector,
            partialCFI: locator.locations.partialCFI,
            domRangeJSON: nil,
            locatorJSON: locatorJSON,
            readiumVersion: readiumVersion,
            chapterTextHash: textHash,
            color: color,
            style: style,
            note: ""
        )
    }

    /// One decoration per highlight; rows whose locator can't be decoded are skipped.
    static func decorations(for highlights: [HighlightRecord]) -> [Decoration] {
        highlights.compactMap { highlight in
            guard let locator = Locator(storedJSONString: highlight.locatorJSON) else { return nil }
            let tint = highlight.highlightColor.uiColor
            let style: Decoration.Style = switch highlight.highlightStyle {
            case .highlight: .highlight(tint: tint)
            case .underline: .underline(tint: tint)
            }
            return Decoration(id: highlight.id, locator: locator, style: style)
        }
    }

    /// Normalized text of one resource, read the same way `BookIndexing` reads it.
    nonisolated static func chapterText(of publication: Publication, href: some URLConvertible) async -> String? {
        guard let link = publication.linkWithHREF(href),
              case let .success(xhtml)? = await publication.get(link)?.read().asString()
        else { return nil }
        return TextNormalizer.normalize(xhtml: xhtml).text
    }
}
