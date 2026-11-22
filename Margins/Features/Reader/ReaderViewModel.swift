import Foundation
import Importing
import Observation
import Persistence
@preconcurrency import ReadiumShared

@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case loading
        case ready(ReaderHostViewController)
        case failed(String)
    }

    static let resumeSaveDelay: Duration = .seconds(2)

    let bookID: String
    private(set) var title: String
    private(set) var state: LoadState = .loading
    /// Hidden while reading (the reader is full-bleed, so the bar would cover text);
    /// a center tap shows it. Loading and error states always show it (see ReaderScreen).
    private(set) var isChromeVisible = false

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let publications: PublicationOpening
    @ObservationIgnored private let containerURL: URL
    @ObservationIgnored private var publication: Publication?
    @ObservationIgnored private var pendingResume: ResumePoint?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var didStartLoading = false
    @ObservationIgnored private var isClosed = false

    init(bookID: String, title: String, environment: AppEnvironment) {
        self.bookID = bookID
        self.title = title
        database = environment.database
        publications = environment.publications
        containerURL = environment.containerURL
    }

    func load() async {
        guard !didStartLoading else { return }
        didStartLoading = true

        // Re-read the row so we resume from the latest saved locator, not a stale list snapshot.
        let book: BookRecord
        do {
            guard let fetched = try await database.book(id: bookID), fetched.deletedAt == nil else {
                state = .failed("This book is no longer in your library.")
                return
            }
            book = fetched
        } catch {
            state = .failed("The library couldn't be read. \(error.localizedDescription)")
            return
        }
        title = book.title

        guard let relpath = book.fileRelpath else {
            state = .failed(PublicationOpeningError.fileMissing.localizedDescription)
            return
        }
        let fileURL = BookPaths.resolve(relpath, in: containerURL)

        let opened: Publication
        do {
            opened = try await publications.openPublication(at: fileURL)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(reason)
            return
        }
        guard !isClosed else {
            // The reader was dismissed while the book was opening.
            opened.close()
            return
        }

        do {
            let host = try ReaderHostViewController(
                publication: opened,
                initialLocation: Locator(storedJSONString: book.lastLocatorJSON),
                model: self
            )
            publication = opened
            state = .ready(host)
        } catch {
            opened.close()
            state = .failed("This book couldn't be displayed. \(error.localizedDescription)")
            return
        }

        do {
            try await database.markOpened(bookID: bookID)
        } catch {
            // Non-fatal: reading works without the last-opened timestamp.
        }
    }

    func toggleChrome() {
        isChromeVisible.toggle()
    }

    /// Called by the navigator delegate; saves the resume point after 2 s without further moves.
    func locationDidChange(_ locator: Locator) {
        guard let point = ResumePoint(locator: locator) else { return }
        pendingResume = point
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resumeSaveDelay)
            guard !Task.isCancelled else { return }
            // Don't call flush(): it cancels debounceTask, which is *this* task, and GRDB
            // abandons writes from cancelled tasks.
            self?.debounceTask = nil
            await self?.savePending()
        }
    }

    /// Writes any pending resume point immediately (close, background).
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await savePending()
    }

    private func savePending() async {
        guard let point = pendingResume else { return }
        pendingResume = nil
        do {
            try await database.updateResumePoint(
                bookID: bookID,
                locatorJSON: point.locatorJSON,
                totalProgression: point.totalProgression
            )
        } catch {
            // Keep it so the next flush retries.
            if pendingResume == nil { pendingResume = point }
        }
    }

    /// Saves and releases the publication. Safe to call more than once.
    func close() async {
        isClosed = true
        await flush()
        publication?.close()
        publication = nil
    }
}
