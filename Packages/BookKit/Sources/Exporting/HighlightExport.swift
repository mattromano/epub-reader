import Foundation
import Persistence

/// Markdown export, one file per book (SPEC §10): Obsidian YAML front matter, then one
/// `[!quote]` callout per highlight with its note and tags inside the callout.
public enum MarkdownExport {
    /// `quotes` are expected in reading order (`QuoteSort.book`); they're written as given.
    /// `calendar` decides the local date for `date_finished` and `exported`.
    public static func book(_ book: BookRecord, quotes: [QuoteItem], now: Date = Date(),
                            calendar: Calendar = .current) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlString(book.title))")
        if !book.authors.isEmpty {
            lines.append("author: \(yamlString(book.authors))")
        }
        let tags = obsidianTags(quotes.flatMap(\.tags))
        if tags.isEmpty {
            lines.append("tags: []")
        } else {
            lines.append("tags:")
            lines += tags.map { "  - \(yamlString($0))" }
        }
        if let finished = book.finishedAt.flatMap(Timestamp.date(from:)) {
            lines.append("date_finished: \(localDate(finished, calendar: calendar))")
        }
        lines.append("highlights: \(quotes.count)")
        lines.append("exported: \(localDate(now, calendar: calendar))")
        lines.append("---")
        lines.append("")
        lines.append("# \(oneLine(book.title))")

        for quote in quotes {
            lines.append("")
            let chapter = oneLine(quote.highlight.chapterTitle ?? "")
            let header = chapter.isEmpty ? "Highlight" : chapter
            lines.append("> [!quote] \(header) · \(quote.highlight.highlightColor.rawValue)")
            lines += calloutLines(quote.highlight.quoteExact.trimmingCharacters(in: .whitespacesAndNewlines))
            let note = (quote.highlight.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                lines.append(">")
                lines += calloutLines("**Note:** " + note)
            }
            let tagLine = obsidianTags(quote.tags).map { "#\($0)" }.joined(separator: " ")
            if !tagLine.isEmpty {
                lines.append(">")
                lines.append("> \(tagLine)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Obsidian tags can't contain spaces or most punctuation: whitespace becomes `-`, other
    /// characters outside letters, digits, `_`, `-`, `/` are dropped. Deduped case-insensitively,
    /// first spelling wins, in the given order; empty results are dropped.
    static func obsidianTags(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let dashed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                .joined(separator: "-")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/"))
            let cleaned = String(String.UnicodeScalarView(dashed.unicodeScalars.filter { allowed.contains($0) }))
            // A tag must contain at least one non-numeric character.
            guard !cleaned.isEmpty, cleaned.contains(where: { !$0.isNumber }) else { continue }
            if seen.insert(cleaned.lowercased()).inserted { result.append(cleaned) }
        }
        return result
    }

    /// Every line of `text` prefixed with `> ` (blank lines become `>`). CRLF counts as one break.
    static func calloutLines(_ text: String) -> [String] {
        lines(of: text).map { $0.isEmpty ? ">" : "> \($0)" }
    }

    /// Splits on any line break, treating CRLF as one (`.newlines` alone splits it in two).
    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
    }

    /// A YAML double-quoted scalar.
    static func yamlString(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                // YAML forbids raw C0 controls, DEL and C1 controls in a document.
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                    escaped += String(format: "\\x%02X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    /// Line breaks become single spaces; surrounding whitespace is trimmed.
    static func oneLine(_ text: String) -> String {
        lines(of: text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// ISO `yyyy-MM-dd` in `calendar`'s time zone. Always Gregorian: YAML/Obsidian dates are ISO,
    /// even when the user's calendar is Buddhist, Japanese, etc.
    static func localDate(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// CSV of all highlights (SPEC §10), RFC 4180: CRLF rows, fields quoted when they contain a
/// comma, quote, CR or LF, quotes doubled.
public enum CSVExport {
    public static let columns = [
        "highlight_id", "book_title", "author", "chapter", "quote", "note", "tags", "color",
        "total_progression", "created_at",
    ]

    public static func highlights(_ quotes: [QuoteItem]) -> String {
        var rows = [columns.map(field).joined(separator: ",")]
        for quote in quotes {
            let h = quote.highlight
            let values = [
                h.id, quote.bookTitle, quote.bookAuthors, h.chapterTitle ?? "", h.quoteExact, h.note ?? "",
                quote.tags.joined(separator: "; "), h.highlightColor.rawValue,
                h.totalProgression.map { String(format: "%.6f", $0) } ?? "", h.createdAt ?? "",
            ]
            rows.append(values.map(field).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 with a byte-order mark, so Excel detects the encoding (Numbers ignores it).
    public static func data(_ quotes: [QuoteItem]) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(highlights(quotes).utf8)
    }

    /// Works on unicode scalars, not Characters: CSV readers split on code points, so a `,` or `"`
    /// followed by a combining mark (one Character) must still be quoted and doubled.
    static func field(_ value: String) -> String {
        let special: Set<Unicode.Scalar> = [",", "\"", "\r", "\n"]
        guard value.unicodeScalars.contains(where: special.contains) else { return value }
        var quoted = String.UnicodeScalarView()
        quoted.append("\"")
        for scalar in value.unicodeScalars {
            if scalar == "\"" { quoted.append("\"") }
            quoted.append(scalar)
        }
        quoted.append("\"")
        return String(quoted)
    }
}

public enum ExportFileName {
    /// A file name for `title` + `ext`: characters illegal on common file systems (`/ \ : * ? " < > |`
    /// and control characters) become spaces, runs of whitespace collapse, at most 80 characters,
    /// "Untitled" when empty.
    public static func make(_ title: String, ext: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let replaced = String(String.UnicodeScalarView(title.unicodeScalars.map { illegal.contains($0) ? " " : $0 }))
        var base = replaced.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        base = String(base.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if base.isEmpty { base = "Untitled" }
        return "\(base).\(ext)"
    }
}
