import Foundation
import Importing
@preconcurrency import ReadiumShared

/// Reads a book's reading-order resources with Readium and hands them to BookKit's
/// `WordIndexer` as plain values (SPEC §6.2). Runs off the main actor; only `Sendable`
/// values leave it.
enum BookIndexing {
    /// Opens the book, reads every reading-order resource as XHTML, indexes it and closes the
    /// publication. Throws only if the publication itself can't be opened; a resource that
    /// can't be read is indexed as 0 words.
    nonisolated static func index(fileURL: URL, opening: PublicationOpening) async throws -> [ChapterIndex] {
        let publication = try await opening.openPublication(at: fileURL)
        defer { publication.close() }

        let titles = await titlesByHref(publication)

        var inputs: [IndexInputChapter] = []
        inputs.reserveCapacity(publication.readingOrder.count)
        for (spineIndex, link) in publication.readingOrder.enumerated() {
            let href = HrefKey.key(link.url())
            let xhtml: String
            if case let .success(string)? = await publication.get(link)?.read().asString() {
                xhtml = string
            } else {
                xhtml = ""
            }
            inputs.append(IndexInputChapter(
                spineIndex: spineIndex,
                href: href,
                title: titles[href],
                // Readium 3.11's OPF parser leaves `linear="no"` itemrefs out of the reading
                // order (they become plain resources) and keeps no linear flag on the link,
                // so every reading-order item is linear.
                isLinear: true,
                xhtml: xhtml
            ))
        }

        return WordIndexer.index(inputs)
    }

    /// Href key → title of the first TOC entry (depth-first) pointing into that resource.
    nonisolated private static func titlesByHref(_ publication: Publication) async -> [String: String] {
        guard case let .success(links) = await publication.tableOfContents() else {
            return [:]
        }
        var titles: [String: String] = [:]
        for entry in TOCEntry.flatten(links) {
            // `TOCEntry.title` substitutes a placeholder for empty titles; use the raw one so
            // the indexer can fall back to "Section N".
            let title = entry.link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { continue }
            let href = HrefKey.key(entry.link.url())
            if titles[href] == nil {
                titles[href] = title
            }
        }
        return titles
    }
}
