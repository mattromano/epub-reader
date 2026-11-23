import Foundation
import Importing
import Observation
import Persistence
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import Tracking

@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case loading
        case ready(ReaderHostViewController)
        case failed(String)
    }

    /// Where a jump (TOC, search result, scrubber) goes.
    enum JumpTarget {
        case locator(Locator)
        case link(Link)
    }

    static let resumeSaveDelay: Duration = .seconds(2)
    static let preferencesSaveDelay: Duration = .seconds(1)

    let bookID: String
    private(set) var title: String
    private(set) var state: LoadState = .loading
    /// Hidden while reading (the reader is full-bleed, so the bar would cover text);
    /// a center tap shows it. Loading and error states always show it (see ReaderScreen).
    private(set) var isChromeVisible = false

    /// The preferences currently submitted to the navigator (and, after the debounce, saved).
    private(set) var preferences: EPUBPreferences = .empty
    /// Fixed-layout books get no Aa sheet (PLAN M1).
    private(set) var isFixedLayout = false
    private(set) var isSearchable = false
    /// Flattened table of contents, in reading order.
    private(set) var tableOfContents: [TOCEntry] = []
    /// 0...1 through the whole book, from the latest location.
    private(set) var currentProgression: Double = 0
    /// Title of the TOC entry containing the current location, when Readium knows it.
    private(set) var currentChapterTitle: String?
    /// Href (without fragment) of the current resource, for marking the TOC.
    private(set) var currentHref: AnyURL?
    /// Created once the book is open, if it's searchable; kept so results survive closing the sheet.
    private(set) var search: SearchViewModel?

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let publications: PublicationOpening
    @ObservationIgnored private let containerURL: URL
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var publication: Publication?
    @ObservationIgnored private var host: ReaderHostViewController?
    /// App-wide defaults (`app_setting[default_preferences]`), used by Reset.
    @ObservationIgnored private var defaultPreferences: EPUBPreferences = .empty
    @ObservationIgnored private var pendingResume: ResumePoint?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreferencesJSON: String?
    @ObservationIgnored private var preferencesDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var didStartLoading = false
    @ObservationIgnored private var isClosed = false
    /// Session tracking for this book (SPEC §6.1).
    @ObservationIgnored private let tracker: TrackerDriver
    /// True from the start of a `go(to:)` call until it returns: every location change in
    /// between is a `jump`, however many fire.
    @ObservationIgnored private var jumpInProgress = false
    /// The next location change is a `jump`: internal link (`didJumpTo`, which also fires for
    /// `go`, before the location change lands), preferences change, rotation, open.
    @ObservationIgnored private var pendingLinkJump = false

    init(bookID: String, title: String, environment: AppEnvironment) {
        self.bookID = bookID
        self.title = title
        database = environment.database
        publications = environment.publications
        containerURL = environment.containerURL
        deviceID = environment.deviceID
        tracker = TrackerDriver(database: environment.database, bookID: bookID)
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

        // A failed read of the defaults just means "no defaults"; it never blocks opening.
        let defaultsJSON = try? await database.settingJSON(forKey: AppSettingKey.defaultPreferences)
        defaultPreferences = ReaderPreferences.decode(defaultsJSON)
        let initialPreferences = ReaderPreferences.initial(
            bookJSON: book.preferencesJSON,
            defaultsJSON: defaultsJSON
        )
        // Thresholds and word index, loaded before the navigator exists so `.open` can be sent
        // before any location change.
        await tracker.prepare()

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

        let initialLocation = Locator(storedJSONString: book.lastLocatorJSON)
        do {
            let host = try ReaderHostViewController(
                publication: opened,
                initialLocation: initialLocation,
                preferences: initialPreferences,
                model: self
            )
            publication = opened
            self.host = host
            preferences = initialPreferences
            isFixedLayout = book.layout == "fixed" || opened.metadata.layout == .fixed
            isSearchable = opened.isSearchable
            if isSearchable {
                search = SearchViewModel(publication: opened)
            }
            if let initialLocation {
                updateLocationInfo(initialLocation)
            }
            startTracking(initialLocation: initialLocation)
            state = .ready(host)
        } catch {
            opened.close()
            state = .failed("This book couldn't be displayed. \(error.localizedDescription)")
            return
        }

        await loadTableOfContents(of: opened)

        do {
            try await database.markOpened(bookID: bookID)
        } catch {
            // Non-fatal: reading works without the last-opened timestamp.
        }
    }

    /// Opens the session and seeds it with the restored location. The navigator's own first
    /// report lands on that same position, so it's marked as a jump too (opening isn't reading).
    private func startTracking(initialLocation: Locator?) {
        tracker.start(context: SessionContext(
            bookID: bookID,
            deviceID: deviceID,
            readingMode: Self.readingMode(of: preferences),
            fontSize: preferences.fontSize,
            isFixedLayout: isFixedLayout
        ))
        if let initialLocation {
            tracker.location(initialLocation, kind: .jump)
        }
        pendingLinkJump = true
    }

    private static func readingMode(of preferences: EPUBPreferences) -> String {
        preferences.scroll == true ? "scroll" : "paginated"
    }

    private func loadTableOfContents(of publication: Publication) async {
        switch await publication.tableOfContents() {
        case let .success(links):
            tableOfContents = TOCEntry.flatten(links)
            search?.tableOfContents = tableOfContents
        case .failure:
            // Non-fatal: the TOC sheet shows an empty state.
            tableOfContents = []
        }
    }

    func toggleChrome() {
        isChromeVisible.toggle()
    }

    // MARK: Location

    /// Called by the navigator delegate; saves the resume point after 2 s without further moves.
    func locationDidChange(_ locator: Locator) {
        updateLocationInfo(locator)
        tracker.location(locator, kind: classifyLocationChange())

        guard let point = ResumePoint(locator: locator) else { return }
        pendingResume = point
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resumeSaveDelay)
            guard !Task.isCancelled else { return }
            // Don't call flush(): it cancels debounceTask, which is *this* task, and GRDB
            // abandons writes from cancelled tasks.
            self?.debounceTask = nil
            await self?.savePendingResume()
        }
    }

    private func classifyLocationChange() -> LocationKind {
        if jumpInProgress || pendingLinkJump {
            pendingLinkJump = false
            return .jump
        }
        return preferences.scroll == true ? .scroll : .pageTurn
    }

    /// Navigator delegate `didJumpTo`: internal links, and every successful `go`.
    func didJumpToLink() {
        markNextLocationAsJump()
    }

    /// The next location change resets the baseline without counting words (rotation etc.).
    func markNextLocationAsJump() {
        pendingLinkJump = true
    }

    private func updateLocationInfo(_ locator: Locator) {
        // Keep the last known progression when Readium doesn't report one.
        if let progression = locator.locations.totalProgression {
            currentProgression = min(max(progression, 0), 1)
        }
        currentChapterTitle = locator.title
        currentHref = locator.href.removingFragment()
    }

    // MARK: Jumps

    /// The single entry point for every jump: TOC, search results and the scrubber.
    /// Returns false if the navigator couldn't go there.
    @discardableResult
    func go(to target: JumpTarget) async -> Bool {
        guard let host else { return false }
        jumpInProgress = true
        defer { jumpInProgress = false }
        switch target {
        case let .locator(locator):
            return await host.go(to: locator)
        case let .link(link):
            return await host.go(to: link)
        }
    }

    /// Scrubber: jumps to a 0...1 position through the whole book.
    @discardableResult
    func seek(toProgression progression: Double) async -> Bool {
        guard let publication else { return false }
        let clamped = min(max(progression, 0), 1)
        guard let locator = await publication.locate(progression: clamped) else { return false }
        return await go(to: .locator(locator))
    }

    // MARK: Preferences

    /// A fresh editor over the current preferences. Build it per render: the editor is a plain
    /// class SwiftUI can't observe, while `preferences` is observable.
    func makeEditor() -> EPUBPreferencesEditor? {
        host?.editor(of: preferences)
    }

    /// Applies preferences live and saves them to the book after 1 s without further changes.
    func apply(_ newPreferences: EPUBPreferences) {
        preferences = newPreferences
        preferencesDidChange()
        host?.submit(newPreferences)
        schedulePreferencesSave(ReaderPreferences.encode(newPreferences))
    }

    /// Back to the app defaults (or Readium's, if none are set). The book row stores `"{}"`
    /// so the book keeps following the defaults on later opens.
    func resetPreferences() {
        preferences = defaultPreferences
        preferencesDidChange()
        host?.submit(defaultPreferences)
        schedulePreferencesSave("{}")
    }

    /// Saves the current (shared) preferences as the defaults for books without their own.
    /// Returns false if the write failed.
    func useAsDefault() async -> Bool {
        let shared = preferences.filterSharedPreferences()
        do {
            try await database.setSettingJSON(
                ReaderPreferences.encode(shared),
                forKey: AppSettingKey.defaultPreferences
            )
            defaultPreferences = shared
            return true
        } catch {
            return false
        }
    }

    /// Reflow moves the location without any reading: snapshot the new context and make the
    /// resulting location change a jump.
    private func preferencesDidChange() {
        tracker.contextChanged(readingMode: Self.readingMode(of: preferences), fontSize: preferences.fontSize)
        markNextLocationAsJump()
    }

    private func schedulePreferencesSave(_ json: String) {
        pendingPreferencesJSON = json
        preferencesDebounceTask?.cancel()
        preferencesDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.preferencesSaveDelay)
            guard !Task.isCancelled else { return }
            // Same rule as the resume save: nil our own handle before writing so nothing
            // cancels this task mid-write (GRDB abandons writes from cancelled tasks).
            self?.preferencesDebounceTask = nil
            await self?.savePendingPreferences()
        }
    }

    // MARK: Scene phase

    /// App went to the background: pauses the session (the tracker checkpoints it).
    func didEnterBackground() {
        tracker.background()
    }

    /// Back in the foreground after `didEnterBackground()` (no-op otherwise).
    func didBecomeActive() {
        tracker.foreground()
    }

    // MARK: Saving

    /// Writes any pending resume point and preferences immediately (close, background).
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        preferencesDebounceTask?.cancel()
        preferencesDebounceTask = nil
        await savePendingResume()
        await savePendingPreferences()
    }

    private func savePendingResume() async {
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

    private func savePendingPreferences() async {
        guard let json = pendingPreferencesJSON else { return }
        pendingPreferencesJSON = nil
        do {
            try await database.updatePreferences(bookID: bookID, preferencesJSON: json)
        } catch {
            // Keep it so the next flush retries, unless a newer value arrived meanwhile.
            if pendingPreferencesJSON == nil { pendingPreferencesJSON = json }
        }
    }

    /// Saves and releases the publication. Safe to call more than once.
    func close() async {
        isClosed = true
        search?.cancel()
        // Ends the session and waits for its writes before the publication goes away.
        await tracker.close()
        await flush()
        publication?.close()
        publication = nil
    }
}
