import Foundation

/// Approximate quote matching for re-anchoring after a book's text changed (SPEC §7 step 3,
/// PLAN M4.5). Ports Hypothesis's `match-quote.ts` scoring: every approximate occurrence of the
/// quote (≤ `min(256, len/2)` edits) is scored as quote 50 / prefix 20 / suffix 20 / position 2,
/// normalized to 0–1. Like `QuoteLocator`, matching ignores whitespace and soft hyphens, and
/// ranges are `Character` offsets in the normalized text.
public enum FuzzyQuoteMatcher {
    /// Hypothesis has no minimum; we accept at ≥ 0.75 of the max score, else the highlight is orphaned.
    public static let acceptThreshold = 0.75

    public struct Match: Sendable, Equatable {
        /// `[char_start, char_end)` in `Character` offsets of the searched text.
        public var range: Range<Int>
        /// Normalized score, 0–1 (1 = exact quote with matching context and position).
        public var score: Double
    }

    static let quoteWeight = 50.0
    static let prefixWeight = 20.0
    static let suffixWeight = 20.0
    static let positionWeight = 2.0

    /// The best-scoring approximate occurrence of `quote` in `text`, or nil if none is within the
    /// error budget. The caller compares `score` to `acceptThreshold`.
    public static func match(quote: String, prefix: String, suffix: String, in text: String,
                             progressionHint: Double?) -> Match? {
        var symbols = SymbolTable()
        let needle = symbols.encode(quote)
        guard !needle.isEmpty else { return nil }

        var haystack: [Int32] = []
        var offsets: [Int] = []
        var textCount = 0
        for ch in text {
            if isKept(ch) {
                haystack.append(symbols.id(ch))
                offsets.append(textCount)
            }
            textCount += 1
        }
        guard !haystack.isEmpty else { return nil }

        let before = symbols.encode(prefix)
        let after = symbols.encode(suffix)
        let maxErrors = min(256, needle.count / 2)
        let candidates = ApproximateSearch.matches(of: needle, in: haystack, maxErrors: maxErrors)
        guard !candidates.isEmpty else { return nil }

        // Position hint in projection indices (offsets are ascending).
        let hintIndex: Double? = progressionHint.map { hint in
            let target = Int((min(max(hint, 0), 1) * Double(textCount)).rounded())
            let index = offsets.firstIndex { $0 >= target } ?? offsets.count
            return Double(index)
        }

        let maxScore = quoteWeight + prefixWeight + suffixWeight + positionWeight
        var best: (candidate: ApproximateSearch.Hit, score: Double)?
        for hit in candidates {
            let quoteScore = 1 - Double(hit.errors) / Double(needle.count)
            let prefixScore = before.isEmpty ? 1 : contextScore(
                before, in: haystack[max(0, hit.start - before.count)..<hit.start])
            let suffixScore = after.isEmpty ? 1 : contextScore(
                after, in: haystack[hit.end..<min(haystack.count, hit.end + after.count)])
            let positionScore = hintIndex.map { 1 - abs(Double(hit.start) - $0) / Double(haystack.count) } ?? 1
            let raw = quoteWeight * quoteScore + prefixWeight * prefixScore
                + suffixWeight * suffixScore + positionWeight * positionScore
            let score = raw / maxScore
            if best == nil || score > best!.score { best = (hit, score) }
        }
        guard let best else { return nil }
        let start = offsets[best.candidate.start]
        let end = offsets[best.candidate.end - 1] + 1
        return Match(range: start..<end, score: min(1, max(0, best.score)))
    }

    /// Hypothesis `textMatchScore`: 1 − (fewest edits to find `pattern` in `window`) / length.
    private static func contextScore(_ pattern: [Int32], in window: ArraySlice<Int32>) -> Double {
        guard !window.isEmpty else { return 0 }
        let errors = ApproximateSearch.minErrors(of: pattern, in: Array(window))
        return 1 - Double(errors) / Double(pattern.count)
    }

    static func isKept(_ ch: Character) -> Bool {
        !ch.isWhitespace && ch != "\u{00AD}"
    }
}

/// Maps Characters to small integers so the DP compares Ints, not grapheme clusters.
private struct SymbolTable {
    private var ids: [Character: Int32] = [:]

    mutating func id(_ ch: Character) -> Int32 {
        if let id = ids[ch] { return id }
        let id = Int32(ids.count)
        ids[ch] = id
        return id
    }

    mutating func encode(_ s: String) -> [Int32] {
        s.filter(FuzzyQuoteMatcher.isKept).map { id($0) }
    }
}

/// Sellers' semi-global edit distance (the pattern may start anywhere in the text) with
/// Ukkonen's cutoff, so the work is about O(k·n) instead of O(m·n).
enum ApproximateSearch {
    struct Hit: Equatable {
        /// Projection indices `[start, end)`.
        var start: Int
        var end: Int
        var errors: Int
    }

    /// Occurrences of `pattern` with ≤ `maxErrors` edits. Runs of adjacent end positions are
    /// collapsed to their fewest-error hit, so each region of the text yields one candidate.
    static func matches(of pattern: [Int32], in text: [Int32], maxErrors k: Int) -> [Hit] {
        let m = pattern.count
        guard m > 0, !text.isEmpty else { return [] }
        let cap = k + 1
        // Column j holds D[i] = edits to match pattern[..<i] ending right after text[j-1].
        var cost = [Int](repeating: cap, count: m + 1)
        var start = [Int](repeating: 0, count: m + 1)
        for i in 0...min(m, k) { cost[i] = i }
        var nextCost = cost
        var nextStart = start
        var lastActive = min(m, k)   // rows above this are > k

        var hits: [Hit] = []
        var run: Hit?
        for j in 0..<text.count {
            let t = text[j]
            nextCost[0] = 0
            nextStart[0] = j + 1
            let top = min(m, lastActive + 1)
            for i in 1...top {
                let above = i <= lastActive ? cost[i] : cap   // stale rows are > k
                var best = cost[i - 1] + (pattern[i - 1] == t ? 0 : 1)
                var bestStart = start[i - 1]
                if above + 1 < best {
                    best = above + 1
                    bestStart = start[i]
                }
                if nextCost[i - 1] + 1 < best {
                    best = nextCost[i - 1] + 1
                    bestStart = nextStart[i - 1]
                }
                nextCost[i] = min(best, cap)
                nextStart[i] = bestStart
            }
            lastActive = top
            while lastActive > 0, nextCost[lastActive] > k { lastActive -= 1 }
            swap(&cost, &nextCost)
            swap(&start, &nextStart)

            if lastActive == m {
                let hit = Hit(start: start[m], end: j + 1, errors: cost[m])
                if let current = run {
                    if hit.errors < current.errors { run = hit }
                } else {
                    run = hit
                }
            } else if let current = run {
                hits.append(current)
                run = nil
            }
        }
        if let run { hits.append(run) }
        return hits
    }

    /// Fewest edits to match `pattern` somewhere inside `text` (no cutoff; short inputs).
    static func minErrors(of pattern: [Int32], in text: [Int32]) -> Int {
        let m = pattern.count
        guard m > 0 else { return 0 }
        var column = Array(0...m)
        var best = column[m]
        for t in text {
            var diagonal = column[0]
            column[0] = 0
            for i in 1...m {
                let above = column[i]
                column[i] = min(diagonal + (pattern[i - 1] == t ? 0 : 1), above + 1, column[i - 1] + 1)
                diagonal = above
            }
            best = min(best, column[m])
        }
        return best
    }
}
