import Foundation

// Forgiving XHTML scanner (SPEC §6.2). No XMLParser: EPUB XHTML is often malformed.
//
// Works on an array of Unicode scalars for O(1) indexing, emits scalars, and converts the
// scalar offsets of block starts to `Character` offsets in one linear pass at the end.
//
// Choices worth knowing (they affect word counts, `text_hash` and later highlight char offsets):
// - Soft hyphen (`&shy;` and raw U+00AD) is dropped: NLTokenizer splits "hyphen\u{AD}ation" in two.
// - Any Unicode whitespace (incl. U+00A0 from `&nbsp;`) collapses to one ASCII space.
// - Inline tags (`<b>`, `<span>`, `<a>`…) add nothing, so `wo<b>rd</b>` stays one word.
// - CDATA content is kept as text; comments, `<?…?>` and `<!DOCTYPE…>` are dropped.
extension TextNormalizer {
    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "br", "hr", "tr", "td",
        "th", "section", "article", "aside", "header", "footer", "figure", "figcaption", "pre",
        "dd", "dt", "ul", "ol", "table", "nav",
    ]

    /// Elements whose content is dropped entirely.
    static let skippedTags: Set<String> = ["head", "script", "style"]

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "copy": "\u{00A9}",
        "shy": "\u{00AD}",
    ]

    static func normalizeImpl(_ xhtml: String) -> NormalizedText {
        var scanner = Scanner(Array(xhtml.unicodeScalars))
        scanner.run()
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scanner.out)
        let text = String(out)
        return NormalizedText(text: text,
                              blockStarts: characterOffsets(ofScalarOffsets: scanner.blockScalarStarts, in: text))
    }

    /// Maps ascending scalar offsets to Character offsets. An offset that falls inside a grapheme
    /// (e.g. a block starting with a combining mark) maps to the grapheme containing it;
    /// duplicates are dropped so the result stays strictly ascending.
    static func characterOffsets(ofScalarOffsets offsets: [Int], in text: String) -> [Int] {
        guard !offsets.isEmpty else { return [] }
        var result: [Int] = []
        result.reserveCapacity(offsets.count)
        var next = 0
        var scalarPos = 0
        var charPos = 0
        for ch in text {
            let width = ch.unicodeScalars.count
            while next < offsets.count, offsets[next] < scalarPos + width {
                if result.last != charPos { result.append(charPos) }
                next += 1
            }
            if next == offsets.count { break }
            scalarPos += width
            charPos += 1
        }
        return result
    }

    private struct Scanner {
        let input: [Unicode.Scalar]
        var i = 0
        var out: [Unicode.Scalar] = []
        var blockScalarStarts: [Int] = []
        var pendingSpace = false
        var pendingBlock = true

        init(_ input: [Unicode.Scalar]) {
            self.input = input
            out.reserveCapacity(input.count / 2)
        }

        mutating func run() {
            let n = input.count
            while i < n {
                let c = input[i]
                if c == "<" {
                    handleMarkup()
                } else if c == "&" {
                    handleEntity()
                } else {
                    emit(c)
                    i += 1
                }
            }
        }

        // MARK: Output

        mutating func emit(_ c: Unicode.Scalar) {
            if c.value < 0x80 {
                // ASCII fast path.
                if c == " " || c == "\n" || c == "\t" || c == "\r" || c.value == 0x0C {
                    if !out.isEmpty { pendingSpace = true }
                    return
                }
                if c.value < 0x20 || c.value == 0x7F { return } // control characters
            } else {
                if c.value == 0xAD { return } // soft hyphen
                if c.properties.isWhitespace {
                    if !out.isEmpty { pendingSpace = true }
                    return
                }
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            if pendingBlock {
                blockScalarStarts.append(out.count)
                pendingBlock = false
            }
            out.append(c)
        }

        mutating func emit(_ s: String) {
            for c in s.unicodeScalars { emit(c) }
        }

        mutating func blockBoundary() {
            if !out.isEmpty { pendingSpace = true }
            pendingBlock = true
        }

        // MARK: Markup

        func matches(_ literal: String, at pos: Int, caseInsensitive: Bool = false) -> Bool {
            var p = pos
            for s in literal.unicodeScalars {
                guard p < input.count else { return false }
                let c = input[p]
                if caseInsensitive {
                    guard Self.lower(c) == Self.lower(s) else { return false }
                } else {
                    guard c == s else { return false }
                }
                p += 1
            }
            return true
        }

        static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
            (c.value >= 65 && c.value <= 90) ? Unicode.Scalar(c.value + 32)! : c
        }

        /// Index of the first occurrence of `literal` at or after `from`, or nil.
        func find(_ literal: String, from: Int, caseInsensitive: Bool = false) -> Int? {
            guard let first = literal.unicodeScalars.first else { return from }
            let firstLower = Self.lower(first)
            var p = from
            while p < input.count {
                let c = input[p]
                if (caseInsensitive ? Self.lower(c) == firstLower : c == first),
                   matches(literal, at: p, caseInsensitive: caseInsensitive) {
                    return p
                }
                p += 1
            }
            return nil
        }

        static func isNameStart(_ c: Unicode.Scalar) -> Bool {
            (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122) || c == "_"
        }

        static func isNameChar(_ c: Unicode.Scalar) -> Bool {
            isNameStart(c) || (c.value >= 48 && c.value <= 57) || c == "-" || c == ":" || c == "."
        }

        mutating func handleMarkup() {
            let n = input.count
            if matches("<!--", at: i) {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                return
            }
            if matches("<![CDATA[", at: i) {
                let end = find("]]>", from: i + 9) ?? n
                for p in (i + 9)..<end { emit(input[p]) }
                i = min(end + 3, n)
                return
            }
            if matches("<!", at: i) || matches("<?", at: i) {
                i = find(">", from: i + 2).map { $0 + 1 } ?? n
                return
            }

            var p = i + 1
            let isClose = p < n && input[p] == "/"
            if isClose { p += 1 }
            guard p < n, Self.isNameStart(input[p]) else {
                // Not a tag ("a < b"): keep the "<" literally.
                emit(input[i])
                i += 1
                return
            }
            var name = String.UnicodeScalarView()
            while p < n, Self.isNameChar(input[p]) {
                name.append(Self.lower(input[p]))
                p += 1
            }
            var tagName = String(name)
            if let colon = tagName.lastIndex(of: ":") { // namespaced, e.g. html:p
                tagName = String(tagName[tagName.index(after: colon)...])
            }

            // Skip attributes to the closing ">", respecting quotes.
            var quote: Unicode.Scalar?
            var selfClosing = false
            while p < n {
                let c = input[p]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == ">" {
                    selfClosing = p > i && input[p - 1] == "/"
                    break
                }
                p += 1
            }
            i = min(p + 1, n)

            if !isClose, !selfClosing, TextNormalizer.skippedTags.contains(tagName) {
                skipElementContent(tagName)
                return
            }
            if TextNormalizer.blockTags.contains(tagName) {
                blockBoundary()
            }
        }

        /// Drops everything up to and including `</name …>`. If the close tag is missing,
        /// an unclosed `<head>` resumes at `<body`; script/style drop the rest.
        mutating func skipElementContent(_ name: String) {
            let n = input.count
            if let close = findTag("</\(name)", from: i) {
                i = find(">", from: close).map { $0 + 1 } ?? n
            } else if name == "head", let body = findTag("<body", from: i) {
                i = body
            } else {
                i = n
            }
        }

        /// Like `find` (case-insensitive), but the match must end the tag name,
        /// so `</head` doesn't match `</header>`.
        func findTag(_ literal: String, from: Int) -> Int? {
            let length = literal.unicodeScalars.count
            var p = from
            while let hit = find(literal, from: p, caseInsensitive: true) {
                let after = hit + length
                if after >= input.count || !Self.isNameChar(input[after]) { return hit }
                p = hit + 1
            }
            return nil
        }

        // MARK: Entities

        mutating func handleEntity() {
            let n = input.count
            // Look for ";" within a short window; otherwise the "&" is literal.
            var p = i + 1
            let limit = min(n, i + 34)
            while p < limit, input[p] != ";", input[p] != "&", input[p] != "<",
                  !input[p].properties.isWhitespace {
                p += 1
            }
            guard p < limit, input[p] == ";", p > i + 1 else {
                emit(input[i])
                i += 1
                return
            }
            var body = String.UnicodeScalarView()
            body.append(contentsOf: input[(i + 1)..<p])
            if let decoded = Self.decodeEntity(String(body)) {
                emit(decoded)
                i = p + 1
            } else {
                emit(input[i]) // unknown entity: keep literally
                i += 1
            }
        }

        static func decodeEntity(_ body: String) -> String? {
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value: UInt32?
                if digits.first == "x" || digits.first == "X" {
                    value = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    value = UInt32(digits, radix: 10)
                }
                guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
                return String(Character(scalar))
            }
            return TextNormalizer.namedEntities[body]
        }
    }
}
