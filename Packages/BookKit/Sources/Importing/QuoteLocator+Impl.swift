import Foundation

// Quote matching that ignores whitespace and soft hyphens (SPEC §7, step 1).
//
// Both sides are reduced to a "projection": their Characters minus whitespace and U+00AD.
// The quote is searched in the chapter's projection (KMP, so pathological input stays linear);
// each hit is scored by how much of the prefix/suffix context matches around it, and mapped
// back to Character offsets in the normalized text.
extension QuoteLocator {
    static func locateImpl(quote: String, prefix: String, suffix: String, in text: String,
                           progressionHint: Double?) -> Range<Int>? {
        let needle = projection(of: quote)
        guard !needle.isEmpty else { return nil }

        // Projection of `text` plus each kept Character's offset in `text`.
        var haystack: [Character] = []
        var offsets: [Int] = []
        haystack.reserveCapacity(text.count)
        offsets.reserveCapacity(text.count)
        var textCount = 0
        for ch in text {
            if isKept(ch) {
                haystack.append(ch)
                offsets.append(textCount)
            }
            textCount += 1
        }

        let hits = occurrences(of: needle, in: haystack)
        guard !hits.isEmpty else { return nil }

        let before = projection(of: prefix)
        let after = projection(of: suffix)
        let target = progressionHint.map { min(max($0, 0), 1) * Double(textCount) }

        var best: (start: Int, score: Int, distance: Double)?
        for start in hits {
            let end = start + needle.count
            let score = commonSuffixLength(before, haystack, endingBefore: start)
                + commonPrefixLength(after, haystack, startingAt: end)
            let distance = target.map { abs(Double(offsets[start]) - $0) } ?? 0
            if let current = best {
                // Hits are ascending, so strict comparisons keep the earliest on a full tie.
                guard score > current.score || (score == current.score && distance < current.distance) else {
                    continue
                }
            }
            best = (start, score, distance)
        }

        guard let best else { return nil }
        return offsets[best.start]..<(offsets[best.start + needle.count - 1] + 1)
    }

    private static func isKept(_ ch: Character) -> Bool {
        !ch.isWhitespace && ch != "\u{00AD}"
    }

    private static func projection(of s: String) -> [Character] {
        s.filter(isKept).map { $0 }
    }

    /// Start indices of every (possibly overlapping) occurrence of `needle` in `haystack`, ascending.
    private static func occurrences(of needle: [Character], in haystack: [Character]) -> [Int] {
        let m = needle.count
        guard m <= haystack.count else { return [] }
        // KMP failure function.
        var failure = [Int](repeating: 0, count: m)
        var k = 0
        for i in 1..<max(m, 1) {
            while k > 0, needle[i] != needle[k] { k = failure[k - 1] }
            if needle[i] == needle[k] { k += 1 }
            failure[i] = k
        }
        var result: [Int] = []
        var q = 0
        for (i, ch) in haystack.enumerated() {
            while q > 0, ch != needle[q] { q = failure[q - 1] }
            if ch == needle[q] { q += 1 }
            if q == m {
                result.append(i - m + 1)
                q = failure[q - 1]
            }
        }
        return result
    }

    /// Length of the longest common suffix of `context` and `haystack[..<end]`.
    private static func commonSuffixLength(_ context: [Character], _ haystack: [Character],
                                           endingBefore end: Int) -> Int {
        var n = 0
        while n < context.count, n < end, context[context.count - 1 - n] == haystack[end - 1 - n] {
            n += 1
        }
        return n
    }

    /// Length of the longest common prefix of `context` and `haystack[start...]`.
    private static func commonPrefixLength(_ context: [Character], _ haystack: [Character],
                                           startingAt start: Int) -> Int {
        var n = 0
        while n < context.count, start + n < haystack.count, context[n] == haystack[start + n] {
            n += 1
        }
        return n
    }
}
