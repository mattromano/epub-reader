import Foundation
import Observation
@preconcurrency import ReadiumShared

/// In-book search (Readium Search guide): runs `publication.search(query:)` and loads every page
/// of results in the background, grouping consecutive matches by their TOC title.
@MainActor
@Observable
final class SearchViewModel {
    enum Phase: Equatable {
        case idle
        case searching
        case finished
        case failed(String)
    }

    struct Result: Identifiable {
        let id: Int
        let locator: Locator
    }

    struct Section: Identifiable {
        let id: Int
        let title: String?
        var results: [Result]
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private(set) var sections: [Section] = []
    private(set) var resultCount = 0
    /// The query the current results belong to.
    private(set) var searchedQuery = ""

    /// Fallback section titles: Readium 3.11 search locators usually have no `title`.
    @ObservationIgnored var tableOfContents: [TOCEntry] = []
    @ObservationIgnored private let publication: Publication
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped on every new search or cancel; a page from an older search is dropped.
    @ObservationIgnored private var generation = 0

    init(publication: Publication) {
        self.publication = publication
    }

    /// Starts a new search for `query`, cancelling any search in progress.
    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        sections = []
        resultCount = 0
        searchedQuery = trimmed
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }
        phase = .searching
        let generation = generation
        task = Task { [weak self] in
            await self?.run(query: trimmed, generation: generation)
        }
    }

    /// Stops the search in progress (keeps results already loaded).
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        if phase == .searching {
            phase = .finished
        }
    }

    /// Clears the query and results.
    func clear() {
        cancel()
        query = ""
        searchedQuery = ""
        sections = []
        resultCount = 0
        phase = .idle
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == self.generation
    }

    private func run(query: String, generation: Int) async {
        let iterator: SearchIterator
        switch await publication.search(query: query) {
        case let .success(it):
            iterator = it
        case let .failure(error):
            if isCurrent(generation) { phase = .failed(Self.message(for: error)) }
            return
        }
        // The iterator releases its resources when deallocated (Closeable.close() is deprecated).

        while isCurrent(generation) {
            switch await iterator.next() {
            case let .success(page?):
                guard isCurrent(generation) else { return }
                append(page.locators)
            case .success(nil):
                if isCurrent(generation) { phase = .finished }
                return
            case let .failure(error):
                if isCurrent(generation) { phase = .failed(Self.message(for: error)) }
                return
            }
        }
    }

    /// Groups consecutive results with the same TOC title (Search guide).
    private func append(_ locators: [Locator]) {
        for locator in locators {
            let result = Result(id: resultCount, locator: locator)
            resultCount += 1
            let title = sectionTitle(for: locator)
            if let last = sections.indices.last, sections[last].title == title {
                sections[last].results.append(result)
            } else {
                sections.append(Section(id: sections.count, title: title, results: [result]))
            }
        }
    }

    /// The locator's own title, else the first TOC entry for the same resource.
    private func sectionTitle(for locator: Locator) -> String? {
        if let title = locator.title, !title.isEmpty { return title }
        let href = locator.href.removingFragment()
        return tableOfContents.first { $0.link.url().removingFragment().isEquivalentTo(href) }?.title
    }

    private static func message(for error: SearchError) -> String {
        switch error {
        case .publicationNotSearchable:
            "This book can't be searched."
        case .badQuery:
            "That search isn't valid. Try different words."
        case .reading:
            "Part of the book couldn't be read while searching."
        }
    }
}
