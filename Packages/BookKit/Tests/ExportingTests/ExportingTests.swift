import Foundation
import Testing
@testable import Exporting
@testable import Persistence

// SPEC §10 exports: Markdown (Obsidian front matter + [!quote] callouts), CSV, file names.

private func book(title: String = "Dune", authors: String = "Frank Herbert",
                  finishedAt: String? = nil) -> BookRecord {
    BookRecord(
        id: "book-1", contentHash: "hash", identifier: nil, title: title, authors: authors, authorsJSON: "[]",
        language: nil, publisher: nil, publishedDate: nil, epubVersion: nil, layout: "reflowable",
        readingProgression: "ltr", fileRelpath: nil, fileSizeBytes: 0, coverRelpath: nil, wordCount: nil,
        chapterCount: nil, indexVersion: 0, status: finishedAt == nil ? "reading" : "finished", rating: nil,
        startedAt: nil, finishedAt: finishedAt, lastLocatorJSON: nil, lastTotalProgression: 0,
        lastOpenedAt: nil, preferencesJSON: "{}", createdAt: "2026-11-01T00:00:00.000Z",
        updatedAt: "2026-11-01T00:00:00.000Z", deletedAt: nil)
}

private func item(id: String = "h1", chapter: String? = "Chapter 3", quote: String, note: String? = "",
                  color: String? = "yellow", tags: [String] = [], total: Double? = 0.25,
                  created: String? = "2026-11-22T10:00:00.000Z", bookTitle: String = "Dune",
                  authors: String = "Frank Herbert") -> QuoteItem {
    let highlight = HighlightRecord(
        id: id, bookID: "book-1", chapterID: nil, spineHref: nil, chapterTitle: chapter, quoteExact: quote,
        quotePrefix: "", quoteSuffix: "", charStart: nil, charEnd: nil, wordIdx: nil, wordCount: nil,
        progression: nil, totalProgression: total, position: nil, cssSelector: nil, partialCFI: nil,
        domRangeJSON: nil, locatorJSON: "{}", readiumVersion: nil, chapterTextHash: nil, anchorStatus: "exact",
        anchorScore: nil, lastAnchoredAt: nil, color: color, note: note, style: "highlight",
        exportReadwiseAt: nil, createdAt: created, updatedAt: created, deletedAt: nil)
    return QuoteItem(highlight: highlight, bookTitle: bookTitle, bookAuthors: authors, tags: tags)
}

private func newYork() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private let exportNow = Timestamp.date(from: "2026-11-23T02:00:00.000Z")! // 2026-11-22 in New York

// MARK: - Minimal YAML front matter reader (just enough for what MarkdownExport writes)

private enum FrontMatterValue: Equatable {
    case scalar(String)
    case list([String])
}

private struct YAMLError: Error, CustomStringConvertible {
    let description: String
}

/// Parses the `---` block: `key: value` pairs where value is a double-quoted scalar (with YAML
/// escapes), a plain scalar, `[]`, or empty followed by `  - "item"` lines. Throws on anything else,
/// including raw control characters (which YAML forbids in a document).
private func parseFrontMatter(_ markdown: String) throws -> [String: FrontMatterValue] {
    let lines = markdown.components(separatedBy: "\n")
    guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
        throw YAMLError(description: "no front matter")
    }
    var result: [String: FrontMatterValue] = [:]
    var currentList: String?
    for line in lines[1..<end] {
        for scalar in line.unicodeScalars where (scalar.value < 0x20 && scalar != "\t") || (0x7F...0x9F).contains(scalar.value) && scalar.value != 0x85 {
            throw YAMLError(description: "raw control character U+\(String(scalar.value, radix: 16)) in \(line.debugDescription)")
        }
        if line.hasPrefix("  - "), let key = currentList {
            guard case .list(var items) = result[key] else { throw YAMLError(description: "orphan item") }
            items.append(try scalarValue(String(line.dropFirst(4))))
            result[key] = .list(items)
            continue
        }
        guard let colon = line.range(of: ": ") ?? (line.hasSuffix(":") ? line.range(of: ":", options: .backwards) : nil)
        else { throw YAMLError(description: "bad line \(line.debugDescription)") }
        let key = String(line[..<colon.lowerBound])
        guard key.allSatisfy({ $0.isLetter || $0 == "_" }) else { throw YAMLError(description: "bad key \(key)") }
        let raw = String(line[colon.upperBound...])
        if raw.isEmpty {
            result[key] = .list([])
            currentList = key
        } else if raw == "[]" {
            result[key] = .list([])
            currentList = nil
        } else {
            result[key] = .scalar(try scalarValue(raw))
            currentList = nil
        }
    }
    return result
}

private func scalarValue(_ raw: String) throws -> String {
    guard raw.hasPrefix("\"") else {
        guard !raw.contains(where: { "\"#:[]{},&*!|>'%@`".contains($0) }) else {
            throw YAMLError(description: "unsafe plain scalar \(raw)")
        }
        return raw
    }
    guard raw.count >= 2, raw.hasSuffix("\"") else { throw YAMLError(description: "unterminated \(raw)") }
    var scalars = Array(raw.unicodeScalars.dropFirst().dropLast())
    var out = String.UnicodeScalarView()
    while !scalars.isEmpty {
        let c = scalars.removeFirst()
        if c == "\"" { throw YAMLError(description: "unescaped quote in \(raw)") }
        guard c == "\\" else { out.append(c); continue }
        guard !scalars.isEmpty else { throw YAMLError(description: "dangling backslash") }
        let e = scalars.removeFirst()
        switch e {
        case "\\": out.append("\\")
        case "\"": out.append("\"")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "x":
            guard scalars.count >= 2, let v = UInt32(String(String.UnicodeScalarView(scalars[0..<2])), radix: 16),
                  let s = Unicode.Scalar(v) else { throw YAMLError(description: "bad \\x") }
            scalars.removeFirst(2)
            out.append(s)
        default: throw YAMLError(description: "unknown escape \\\(e)")
        }
    }
    return String(out)
}

// MARK: - Markdown

@Suite struct MarkdownExportTests {
    @Test func goldenOutput() {
        let quotes = [
            item(id: "h1", chapter: "Chapter 3", quote: "Fear is the mind-killer.", note: "",
                 color: "yellow", tags: ["Philosophy", "deep thoughts", "2024"]),
            item(id: "h2", chapter: nil, quote: "Line one\n\nLine three", note: "My note\nsecond line",
                 color: "green", tags: ["deep thoughts"]),
        ]
        let markdown = MarkdownExport.book(
            book(title: "Dune: \"Messiah\"", finishedAt: "2026-11-22T03:30:00.000Z"), // 2026-11-21 in New York
            quotes: quotes, now: exportNow, calendar: newYork())
        let expected = """
            ---
            title: "Dune: \\"Messiah\\""
            author: "Frank Herbert"
            tags:
              - "Philosophy"
              - "deep-thoughts"
            date_finished: 2026-11-21
            highlights: 2
            exported: 2026-11-22
            ---

            # Dune: "Messiah"

            > [!quote] Chapter 3 · yellow
            > Fear is the mind-killer.
            >
            > #Philosophy #deep-thoughts

            > [!quote] Highlight · green
            > Line one
            >
            > Line three
            >
            > **Note:** My note
            > second line
            >
            > #deep-thoughts

            """
        #expect(markdown == expected)
    }

    @Test(arguments: [
        "Dune: \"Messiah\"", "C:\\Books\\Dune", "Title: with: colons", "# not a comment", "- not a list",
        "[bracketed]", "{braces}", "tab\there", "line\nbreak", "cr\rhere", "bell\u{7}", "del\u{7F}", "c1\u{85}\u{9F}",
        "'single'", "Brontë — Jane Eyre 📚", "yes", "null", "",
    ])
    func titleRoundTripsThroughYAML(title: String) throws {
        let markdown = MarkdownExport.book(book(title: title, authors: title), quotes: [], now: exportNow,
                                           calendar: newYork())
        let front = try parseFrontMatter(markdown)
        #expect(front["title"] == .scalar(title))
        if title.isEmpty {
            #expect(front["author"] == nil)
        } else {
            #expect(front["author"] == .scalar(title))
        }
    }

    @Test func headingStaysOnOneLine() {
        let markdown = MarkdownExport.book(book(title: "Part\nTwo\r\nThree"), quotes: [], now: exportNow,
                                           calendar: newYork())
        let body = markdown.components(separatedBy: "---\n").last ?? ""
        #expect(body == "\n# Part Two Three\n")
    }

    @Test func frontMatterOmitsOptionalFields() throws {
        let markdown = MarkdownExport.book(book(title: "Plain", authors: ""), quotes: [item(quote: "q")],
                                           now: exportNow, calendar: newYork())
        let front = try parseFrontMatter(markdown)
        #expect(front == [
            "title": .scalar("Plain"), "tags": .list([]), "highlights": .scalar("1"),
            "exported": .scalar("2026-11-22"),
        ])
        #expect(markdown.contains("tags: []\n"))
    }

    @Test func tagsBecomeObsidianTags() throws {
        let quotes = [
            item(id: "a", quote: "a", tags: ["deep thoughts", "Sci-Fi", "2024", "12 34", "to/read"]),
            item(id: "b", quote: "b", tags: ["Deep Thoughts", "rock & roll", "#hash", "  padded  ", "!!!"]),
        ]
        let markdown = MarkdownExport.book(book(), quotes: quotes, now: exportNow, calendar: newYork())
        let front = try parseFrontMatter(markdown)
        // "12 34" becomes "12-34": the dash is a non-numeric character, so Obsidian accepts it.
        #expect(front["tags"] == .list(["deep-thoughts", "Sci-Fi", "12-34", "to/read", "rock--roll", "hash", "padded"]))
        #expect(markdown.contains("> #deep-thoughts #Sci-Fi #12-34 #to/read\n"))
        #expect(markdown.contains("> #Deep-Thoughts #rock--roll #hash #padded\n"))
        #expect(!markdown.contains("2024"))
    }

    @Test func numericOnlyTagsOnlyMeansNoTagLine() {
        let markdown = MarkdownExport.book(book(), quotes: [item(quote: "q", tags: ["2024", "7"])], now: exportNow,
                                           calendar: newYork())
        #expect(markdown.hasSuffix("> [!quote] Chapter 3 · yellow\n> q\n"))
        #expect(markdown.contains("tags: []\n"))
    }

    @Test func datesUseTheCalendarTimeZone() throws {
        let finished = "2026-11-22T03:30:00.000Z"
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let ny = try parseFrontMatter(MarkdownExport.book(book(finishedAt: finished), quotes: [], now: exportNow,
                                                          calendar: newYork()))
        let tk = try parseFrontMatter(MarkdownExport.book(book(finishedAt: finished), quotes: [], now: exportNow,
                                                          calendar: tokyo))
        #expect(ny["date_finished"] == .scalar("2026-11-21"))
        #expect(ny["exported"] == .scalar("2026-11-22"))
        #expect(tk["date_finished"] == .scalar("2026-11-22"))
        #expect(tk["exported"] == .scalar("2026-11-23"))
    }

    @Test func datesAreGregorianWhateverTheCalendar() throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/New_York")!
        let front = try parseFrontMatter(MarkdownExport.book(
            book(finishedAt: "2026-11-22T03:30:00.000Z"), quotes: [], now: exportNow, calendar: buddhist))
        #expect(front["date_finished"] == .scalar("2026-11-21"))
        #expect(front["exported"] == .scalar("2026-11-22"))
    }

    @Test func dateFinishedOnlyWhenFinished() throws {
        let reading = try parseFrontMatter(MarkdownExport.book(book(), quotes: [], now: exportNow, calendar: newYork()))
        #expect(reading["date_finished"] == nil)
        let garbage = try parseFrontMatter(MarkdownExport.book(book(finishedAt: "not a date"), quotes: [],
                                                               now: exportNow, calendar: newYork()))
        #expect(garbage["date_finished"] == nil)
    }

    @Test func calloutHeaderUsesChapterAndColor() {
        func header(_ chapter: String?, color: String? = "blue") -> String {
            let md = MarkdownExport.book(book(), quotes: [item(chapter: chapter, quote: "q", color: color)],
                                         now: exportNow, calendar: newYork())
            return md.components(separatedBy: "\n").first { $0.hasPrefix("> [!quote]") } ?? ""
        }
        #expect(header("Chapter 3") == "> [!quote] Chapter 3 · blue")
        #expect(header(nil) == "> [!quote] Highlight · blue")
        #expect(header("") == "> [!quote] Highlight · blue")
        #expect(header("   \n ") == "> [!quote] Highlight · blue")
        #expect(header("  Part\nOne ") == "> [!quote] Part One · blue")
        #expect(header("Part\r\nOne") == "> [!quote] Part One · blue")
        #expect(header("X", color: nil) == "> [!quote] X · yellow")
        #expect(header("X", color: "orange") == "> [!quote] X · yellow")
    }

    @Test func everyCalloutLineIsPrefixed() {
        let quotes = [item(quote: "first\nsecond\n\nfourth", note: "  note one\n\nnote three  ", tags: ["t"])]
        let md = MarkdownExport.book(book(), quotes: quotes, now: exportNow, calendar: newYork())
        let callout = md.components(separatedBy: "\n\n").last!.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(callout == [
            "> [!quote] Chapter 3 · yellow", "> first", "> second", ">", "> fourth", ">", "> **Note:** note one",
            ">", "> note three", ">", "> #t",
        ])
        #expect(callout.allSatisfy { $0 == ">" || $0.hasPrefix("> ") })
    }

    @Test func crlfAndSurroundingBlankLinesDoNotAddLines() {
        let quotes = [item(quote: "\nfirst\r\nsecond\r\n", note: "a\r\nb")]
        let md = MarkdownExport.book(book(), quotes: quotes, now: exportNow, calendar: newYork())
        #expect(md.hasSuffix("""
            > [!quote] Chapter 3 · yellow
            > first
            > second
            >
            > **Note:** a
            > b

            """))
        #expect(!md.contains("\r"))
    }

    @Test func blankNoteIsOmitted() {
        for note: String? in [nil, "", "  \n\t "] {
            let md = MarkdownExport.book(book(), quotes: [item(quote: "q", note: note)], now: exportNow,
                                         calendar: newYork())
            #expect(md.hasSuffix("> [!quote] Chapter 3 · yellow\n> q\n"))
        }
    }

    @Test func quotesAreWrittenInGivenOrder() {
        let quotes = [item(id: "b", quote: "second"), item(id: "a", quote: "first")]
        let md = MarkdownExport.book(book(), quotes: quotes, now: exportNow, calendar: newYork())
        let second = md.range(of: "> second")!.lowerBound
        let first = md.range(of: "> first")!.lowerBound
        #expect(second < first)
        #expect(md.contains("highlights: 2\n"))
    }
}

// MARK: - CSV

/// RFC 4180 reader: CRLF record separators, quoted fields with doubled quotes. Works on unicode
/// scalars so a delimiter followed by a combining mark is still a delimiter.
private func parseCSV(_ text: String) throws -> [[String]] {
    var records: [[String]] = []
    var record: [String] = []
    var field = String.UnicodeScalarView()
    var scalars = Array(text.unicodeScalars)[...]
    var quoted = false
    var atFieldStart = true
    while let c = scalars.popFirst() {
        if quoted {
            if c == "\"" {
                if scalars.first == "\"" { scalars.removeFirst(); field.append("\"") } else { quoted = false }
            } else {
                field.append(c)
            }
            continue
        }
        switch c {
        case "\"" where atFieldStart:
            quoted = true
            atFieldStart = false
        case "\"":
            throw YAMLError(description: "stray quote in unquoted field")
        case ",":
            record.append(String(field)); field = .init(); atFieldStart = true
        case "\r":
            guard scalars.popFirst() == "\n" else { throw YAMLError(description: "bare CR outside quotes") }
            record.append(String(field)); field = .init(); atFieldStart = true
            records.append(record); record = []
        case "\n":
            throw YAMLError(description: "bare LF outside quotes")
        default:
            field.append(c)
            atFieldStart = false
        }
    }
    guard !quoted else { throw YAMLError(description: "unterminated quote") }
    guard record.isEmpty, field.isEmpty else { throw YAMLError(description: "last record not CRLF-terminated") }
    return records
}

@Suite struct CSVExportTests {
    private let header = "highlight_id,book_title,author,chapter,quote,note,tags,color,total_progression,created_at"

    @Test func headerIsSpecColumns() {
        #expect(CSVExport.columns == [
            "highlight_id", "book_title", "author", "chapter", "quote", "note", "tags", "color",
            "total_progression", "created_at",
        ])
        #expect(CSVExport.highlights([]) == header + "\r\n")
    }

    @Test func goldenRows() {
        let quotes = [
            item(id: "h1", chapter: "Chapter 3", quote: "Plain quote", note: "", color: "green",
                 tags: ["Alpha", "beta"], total: 0.25),
            item(id: "h2", chapter: nil, quote: "Hello, \"world\"\nnext", note: nil, color: nil, tags: [],
                 total: nil, created: nil, bookTitle: "A, B", authors: ""),
        ]
        let expected = header + "\r\n"
            + "h1,Dune,Frank Herbert,Chapter 3,Plain quote,,Alpha; beta,green,0.250000,2026-11-22T10:00:00.000Z\r\n"
            + "h2,\"A, B\",,,\"Hello, \"\"world\"\"\nnext\",,,yellow,,\r\n"
        #expect(CSVExport.highlights(quotes) == expected)
    }

    @Test func fieldQuoting() {
        #expect(CSVExport.field("plain") == "plain")
        #expect(CSVExport.field("") == "")
        #expect(CSVExport.field("a,b") == "\"a,b\"")
        #expect(CSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExport.field("a\nb") == "\"a\nb\"")
        #expect(CSVExport.field("a\rb") == "\"a\rb\"")
        #expect(CSVExport.field("a\r\nb") == "\"a\r\nb\"")
        #expect(CSVExport.field(" padded ") == " padded ")
    }

    @Test func delimiterFollowedByCombiningMarkIsStillQuoted() {
        // "," + U+0301 and "\"" + U+0301 are single Characters, but CSV readers work on code points.
        #expect(CSVExport.field("a,\u{301}b") == "\"a,\u{301}b\"")
        #expect(CSVExport.field("x\"\u{301}y") == "\"x\"\"\u{301}y\"")
        #expect(CSVExport.field("a\n\u{301}b") == "\"a\n\u{301}b\"")
        #expect(CSVExport.field("a\u{200D},b") == "\"a\u{200D},b\"")
    }

    @Test func roundTripsThroughRFC4180Reader() throws {
        let nasty = [
            "comma, here", "quote \" here", "\"starts and ends\"", "multi\nline", "crlf\r\nline", "cr\ronly",
            "trailing comma,", ",\u{301}combining", "\"\u{301}", "emoji 👩‍👩‍👧, ok", "", "  spaces  ",
        ]
        let quotes = nasty.enumerated().map { index, text in
            item(id: "h\(index)", chapter: text, quote: text, note: text, tags: [text, "second"],
                 total: Double(index) / 10, bookTitle: text, authors: text)
        }
        let records = try parseCSV(CSVExport.highlights(quotes))
        #expect(records.count == nasty.count + 1)
        #expect(records[0] == CSVExport.columns)
        for (index, text) in nasty.enumerated() {
            let row = records[index + 1]
            #expect(row.count == 10)
            #expect(row == ["h\(index)", text, text, text, text, text, "\(text); second", "yellow",
                            String(format: "%.6f", Double(index) / 10), "2026-11-22T10:00:00.000Z"])
        }
    }

    @Test func rowsEndWithCRLF() {
        let csv = CSVExport.highlights([item(id: "a", quote: "x"), item(id: "b", quote: "y")])
        #expect(csv.hasSuffix("\r\n"))
        let rows = csv.components(separatedBy: "\r\n")
        #expect(rows.count == 4) // header, two rows, trailing empty
        #expect(rows.last == "")
        #expect(!rows.dropLast().contains { $0.contains("\n") || $0.contains("\r") })
    }

    @Test func dataHasUTF8BOM() {
        let quotes = [item(quote: "Brontë — café")]
        let data = CSVExport.data(quotes)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(data.dropFirst(3) == Data(CSVExport.highlights(quotes).utf8))
        #expect(String(data: data.dropFirst(3), encoding: .utf8)?.contains("Brontë — café") == true)
    }

    @Test func progressionIsLocaleIndependent() {
        let csv = CSVExport.highlights([item(quote: "x", total: 0.123456789)])
        #expect(csv.contains(",0.123457,"))
    }
}

// MARK: - File names

@Suite struct ExportFileNameTests {
    @Test func illegalCharactersBecomeSpaces() {
        #expect(ExportFileName.make("A/B", ext: "md") == "A B.md")
        #expect(ExportFileName.make("a/b\\c:d*e?f\"g<h>i|j", ext: "md") == "a b c d e f g h i j.md")
        #expect(ExportFileName.make("Dune: Messiah", ext: "csv") == "Dune Messiah.csv")
        #expect(ExportFileName.make("bell\u{7}null\u{0}del\u{7F}", ext: "md") == "bell null del.md")
    }

    @Test func whitespaceCollapses() {
        #expect(ExportFileName.make("  lots   of\t\tspace\n here \r\n", ext: "md") == "lots of space here.md")
        #expect(ExportFileName.make("a / b", ext: "md") == "a b.md")
        #expect(ExportFileName.make("nbsp\u{A0}\u{A0}here", ext: "md") == "nbsp here.md")
    }

    @Test func limitedTo80Characters() {
        let long = String(repeating: "a", count: 200)
        #expect(ExportFileName.make(long, ext: "md") == String(repeating: "a", count: 80) + ".md")
        let emoji = String(repeating: "📚", count: 100)
        #expect(ExportFileName.make(emoji, ext: "md") == String(repeating: "📚", count: 80) + ".md")
        // Cut lands on a space: trimmed, never ends in whitespace.
        let words = String(repeating: "a", count: 79) + " tail"
        #expect(ExportFileName.make(words, ext: "md") == String(repeating: "a", count: 79) + ".md")
        #expect(ExportFileName.make(String(repeating: "b", count: 80), ext: "md").count == 83)
    }

    @Test func emptyBecomesUntitled() {
        for title in ["", "   ", "///", "...", ". . .", "\n\t", "?*"] {
            #expect(ExportFileName.make(title, ext: "md") == "Untitled.md", "\(title.debugDescription)")
        }
    }

    @Test func dotsTrimmed() {
        #expect(ExportFileName.make("The End...", ext: "md") == "The End.md")
        #expect(ExportFileName.make("Wait. . .", ext: "md") == "Wait.md")
        #expect(ExportFileName.make(".hidden", ext: "md") == "hidden.md")
        #expect(ExportFileName.make("v1.2 notes", ext: "csv") == "v1.2 notes.csv")
    }

    @Test func unicodeKept() {
        #expect(ExportFileName.make("Brontë — Jane Eyre 📚", ext: "md") == "Brontë — Jane Eyre 📚.md")
    }
}
