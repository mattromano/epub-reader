import CryptoKit
import Foundation
import NaturalLanguage

extension WordIndexer {
    /// Long blocks get an extra anchor about every this many characters.
    static let maxAnchorSpacing = 1500

    static func indexImpl(_ chapters: [IndexInputChapter]) -> [ChapterIndex] {
        var running = 0
        var result: [ChapterIndex] = []
        result.reserveCapacity(chapters.count)
        let tokenizer = NLTokenizer(unit: .word)
        for input in chapters {
            var chapter = indexChapter(input, tokenizer: tokenizer)
            chapter.cumWordsStart = running
            if input.isLinear { running += chapter.wordCount }
            result.append(chapter)
        }
        return result
    }

    static func title(for input: IndexInputChapter) -> String {
        let trimmed = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Section \(input.spineIndex + 1)" : trimmed
    }

    /// Anchor char offsets: every block start, plus one every `maxAnchorSpacing` chars inside long blocks.
    static func anchorOffsets(blockStarts: [Int], charCount: Int) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(blockStarts.count + charCount / maxAnchorSpacing)
        for (k, start) in blockStarts.enumerated() {
            let end = k + 1 < blockStarts.count ? blockStarts[k + 1] : charCount
            var offset = start
            while offset < end {
                offsets.append(offset)
                offset += maxAnchorSpacing
            }
        }
        return offsets
    }

    static func indexChapter(_ input: IndexInputChapter, tokenizer: NLTokenizer) -> ChapterIndex {
        let normalized = TextNormalizer.normalize(xhtml: input.xhtml)
        let text = normalized.text
        let charCount = text.count
        let offsets = anchorOffsets(blockStarts: normalized.blockStarts, charCount: charCount)

        // Walk anchor offsets to String.Index once (ascending, so linear overall).
        var anchorIndices: [String.Index] = []
        anchorIndices.reserveCapacity(offsets.count)
        var idx = text.startIndex
        var pos = 0
        for offset in offsets {
            idx = text.index(idx, offsetBy: offset - pos)
            pos = offset
            anchorIndices.append(idx)
        }

        // Count tokens; a token belongs before anchor k when it starts before the anchor.
        var cumAtAnchor = [Int](repeating: 0, count: offsets.count)
        var wordCount = 0
        var next = 0
        if !text.isEmpty {
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                while next < anchorIndices.count, anchorIndices[next] <= range.lowerBound {
                    cumAtAnchor[next] = wordCount
                    next += 1
                }
                wordCount += 1
                return true
            }
        }
        while next < anchorIndices.count {
            cumAtAnchor[next] = wordCount
            next += 1
        }

        let anchors = offsets.indices.map { k in
            BlockAnchor(blockIndex: k,
                        progression: charCount > 0 ? Double(offsets[k]) / Double(charCount) : 0,
                        charOffset: offsets[k],
                        cumWordOffset: cumAtAnchor[k])
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return ChapterIndex(
            spineIndex: input.spineIndex, href: input.href, title: title(for: input),
            isLinear: input.isLinear, wordCount: wordCount, charCount: charCount, cumWordsStart: 0,
            textHash: digest.map { String(format: "%02x", $0) }.joined(), anchors: anchors)
    }
}

extension WordIndex {
    func totalWordsImpl() -> Int {
        chapters.reduce(0) { $0 + ($1.isLinear ? $1.wordCount : 0) }
    }

    func chapter(href: String) -> ChapterIndex? {
        chapters.first { $0.href == href }
    }

    func wordIdxImpl(href: String, progression: Double) -> Int? {
        guard let chapter = chapter(href: href) else { return nil }
        let p = progression.isFinite ? min(max(progression, 0), 1) : 0
        return chapter.cumWordsStart + Self.offset(in: chapter, at: p)
    }

    /// Floor of the piecewise-linear interpolation through (0, 0), the anchors, and (1, wordCount).
    static func offset(in chapter: ChapterIndex, at p: Double) -> Int {
        let anchors = chapter.anchors
        // Last anchor with progression <= p (binary search; anchors ascend by progression).
        var lo = 0
        var hi = anchors.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid].progression <= p { lo = mid + 1 } else { hi = mid }
        }
        let leftP: Double, leftW: Double, rightP: Double, rightW: Double
        if lo == 0 {
            leftP = 0
            leftW = 0
        } else {
            leftP = anchors[lo - 1].progression
            leftW = Double(anchors[lo - 1].cumWordOffset)
        }
        if lo < anchors.count {
            rightP = anchors[lo].progression
            rightW = Double(anchors[lo].cumWordOffset)
        } else {
            rightP = 1
            rightW = Double(chapter.wordCount)
        }
        let value: Double
        if rightP > leftP {
            let t = (p - leftP) / (rightP - leftP)
            value = leftW + (rightW - leftW) * min(max(t, 0), 1)
        } else {
            value = p >= rightP ? rightW : leftW
        }
        return min(max(Int(value.rounded(.down)), 0), chapter.wordCount)
    }
}
