import Foundation
import Importing
import Observation
import Persistence

/// Builds word indexes in the background, one book at a time (PLAN M2, SPEC §6.2): after an
/// import, and on launch for any book whose `index_version` is behind `WordIndexer.version`.
@MainActor
@Observable
final class IndexingService {
    /// Books queued or being indexed right now.
    private(set) var indexingBookIDs: Set<String> = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let publications: PublicationOpening
    @ObservationIgnored private let containerURL: URL
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(database: AppDatabase, publications: PublicationOpening, containerURL: URL) {
        self.database = database
        self.publications = publications
        self.containerURL = containerURL
    }

    /// Queues a book (no-op if it's already queued or being indexed).
    func enqueue(bookID: String) {
        guard !indexingBookIDs.contains(bookID) else { return }
        indexingBookIDs.insert(bookID)
        queue.append(bookID)
        startWorkerIfNeeded()
    }

    /// Queues every live book whose index is missing or out of date.
    func indexPendingOnLaunch() async {
        do {
            let books = try await database.booksNeedingIndex(version: WordIndexer.version)
            for book in books {
                enqueue(bookID: book.id)
            }
        } catch {
            // Non-fatal: the next launch (or the next import) tries again.
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let bookID = queue.removeFirst()
            await process(bookID: bookID)
            indexingBookIDs.remove(bookID)
        }
        worker = nil
    }

    /// Indexes one book. Every outcome stamps `index_version` (index saved, or skipped), so a
    /// book never shows "Indexing…" forever; only a failed DB write leaves it for next launch.
    private func process(bookID: String) async {
        let database = database
        let publications = publications
        let containerURL = containerURL
        let version = WordIndexer.version

        await Task.detached(priority: .utility) {
            do {
                guard let book = try await database.book(id: bookID) else { return } // deleted meanwhile
                guard book.layout != "fixed", let relpath = book.fileRelpath else {
                    // Fixed layout: time is tracked, words aren't (Q7). No file: nothing to read.
                    try await database.markIndexSkipped(bookID: bookID, version: version)
                    return
                }
                let fileURL = BookPaths.resolve(relpath, in: containerURL)
                let chapters: [ChapterIndex]
                do {
                    chapters = try await BookIndexing.index(fileURL: fileURL, opening: publications)
                } catch {
                    // The whole book failed to open: word_count stays NULL.
                    try await database.markIndexSkipped(bookID: bookID, version: version)
                    return
                }
                try await database.saveIndex(bookID: bookID, chapters: chapters, version: version)
            } catch {
                // DB failure: leave index_version as is so the next launch retries.
            }
        }.value
    }
}
