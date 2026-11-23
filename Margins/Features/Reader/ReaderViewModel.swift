import Foundation
import GRDB
import Importing
import Metrics
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
    /// The book's highlights in reading order (DB is the source of truth; observed live).
    private(set) var highlights: [HighlightRecord] = []
    /// The book's bookmarks in reading order (observed live).
    private(set) var bookmarks: [BookmarkRecord] = []
    /// The latest navigator location, for the bookmark toggle.
    private(set) var currentLocator: Locator?
    /// "X min left in chapter · Y h Z m in book" inputs (SPEC §6.3); nil until indexed with a pace.
    private(set) var timeLeft: TimeLeft?
    @ObservationIgnored private var timeLeftTask: Task<Void, Never>?
    /// Which stats the tap panel and the always-on line show (observed live from Settings).
    private(set) var statsSettings: ReaderStatsSettings = .default
    /// The tap panel's stats, in the configured order, leaving out ones with no value.
    private(set) var panelStats: [ReaderStatValue] = []
    /// The always-on line's stats (compact); empty when the line is off or has nothing to show.
    private(set) var lineStats: [ReaderStatValue] = []
    /// Space for the always-on line is reserved in the navigator when the book opens, so turning
    /// the line on only takes effect on the next open (reader-stats design, call 8).
    private(set) var reservesStatsLine = false
    @ObservationIgnored private var statsBaseline: ReaderStatsBaseline?
    @ObservationIgnored private var statsTimer: Task<Void, Never>?
    @ObservationIgnored private var baselineTask: Task<Void, Never>?
    @ObservationIgnored private var baselineChapterHref: AnyURL?
    /// Set to open the highlight editor (after a tap on a highlight, or Color / Note).
    var editingHighlight: HighlightEditorTarget?
    /// A failed highlight or bookmark write, shown as an alert.
    var actionError: String?

    @ObservationIgnored let database: AppDatabase
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
    @ObservationIgnored private let widgets: WidgetPublisher
    /// True from the start of a `go(to:)` call until it returns: every location change in
    /// between is a `jump`, however many fire.
    @ObservationIgnored private var jumpInProgress = false
    /// The next location change is a `jump`: internal link (`didJumpTo`, which also fires for
    /// `go`, before the location change lands), preferences change, rotation, open.
    @ObservationIgnored private var pendingLinkJump = false
    /// Opened at a highlight (`initialLocatorJSON`): when set, the resume point isn't saved
    /// until the first page turn or scroll, so peeking at a quote keeps your reading position.
    @ObservationIgnored private let initialLocatorJSON: String?
    @ObservationIgnored private var holdsResumePoint = false
    /// Opened at a highlight in scroll mode: nudge it out from under the chrome once the
    /// navigator reports its first location (see `ReaderHostViewController.revealScrolledTarget`).
    @ObservationIgnored private var revealsInitialTarget = false
    /// Normalized text per href key, for computing highlight char ranges (SPEC §7).
    @ObservationIgnored private var chapterTexts: [String: String] = [:]
    @ObservationIgnored private var lastHighlightColor: HighlightColor = .yellow
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(bookID: String, title: String, environment: AppEnvironment, initialLocatorJSON: String? = nil) {
        self.bookID = bookID
        self.title = title
        self.initialLocatorJSON = initialLocatorJSON
        database = environment.database
        publications = environment.publications
        containerURL = environment.containerURL
        deviceID = environment.deviceID
        tracker = TrackerDriver(database: environment.database, bookID: bookID)
        widgets = environment.widgets
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

        let overrideLocation = Locator(storedJSONString: initialLocatorJSON)
        holdsResumePoint = overrideLocation != nil
        revealsInitialTarget = initialPreferences.scroll == true && overrideLocation?.text.highlight != nil
        let initialLocation = overrideLocation ?? Locator(storedJSONString: book.lastLocatorJSON)
        lastHighlightColor = (try? await database.lastHighlightColor()) ?? .yellow
        let fixedLayout = book.layout == "fixed" || opened.metadata.layout == .fixed
        statsSettings = (try? await database.reader.read { try MetricsQueries.readerStatsSettings($0) }) ?? .default
        reservesStatsLine = statsSettings.lineEnabled && !fixedLayout
        guard !isClosed else {
            // Dismissed while the settings above were loading.
            opened.close()
            return
        }
        do {
            let host = try ReaderHostViewController(
                publication: opened,
                initialLocation: initialLocation,
                preferences: initialPreferences,
                reservesStatsLine: reservesStatsLine,
                model: self
            )
            publication = opened
            self.host = host
            preferences = initialPreferences
            isFixedLayout = fixedLayout
            isSearchable = opened.isSearchable
            if isSearchable {
                search = SearchViewModel(publication: opened)
            }
            if let initialLocation {
                updateLocationInfo(initialLocation)
            }
            startTracking(initialLocation: initialLocation)
            currentLocator = initialLocation
            startObserving()
            state = .ready(host)
            tracker.onSessionEnded = { [weak self] in self?.reloadStatsBaseline() }
            reloadStatsBaseline()
            updateStatsTimer()
        } catch {
            opened.close()
            state = .failed("This book couldn't be displayed. \(error.localizedDescription)")
            return
        }

        await loadTableOfContents(of: opened)

        let database = database, bookID = bookID
        Task.detached(priority: .utility) {
            await Self.reanchorStaleHighlights(bookID: bookID, publication: opened, database: database)
        }

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

    /// SPEC §7 step 3: highlights whose chapter text changed since they were anchored (the book
    /// file was replaced) are re-anchored against the current text: an exact quote search, then a
    /// fuzzy match (M4.5, which also rewrites the locator so the decoration follows), else
    /// orphaned. The highlight observation re-applies decorations on the write. Failures are
    /// non-fatal; the next open retries.
    nonisolated private static func reanchorStaleHighlights(
        bookID: String, publication: Publication, database: AppDatabase
    ) async {
        guard let stale = try? await database.staleAnchors(bookID: bookID), !stale.isEmpty else { return }
        var texts: [String: String] = [:]
        for anchor in stale {
            let text: String
            if let cached = texts[anchor.chapterHref] {
                text = cached
            } else {
                guard let href = AnyURL(string: anchor.chapterHref),
                      let loaded = await HighlightCapture.chapterText(of: publication, href: href) else { continue }
                // Only trust the text if it's the version the index hashed.
                guard TextNormalizer.textHash(loaded) == anchor.currentTextHash else { continue }
                texts[anchor.chapterHref] = loaded
                text = loaded
            }
            let outcome = HighlightAnchoring.reanchor(anchor.highlight, in: text)
            try? await database.applyAnchor(id: anchor.highlight.id, outcome: outcome,
                                            textHash: anchor.currentTextHash)
        }
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
        refreshStats()
        updateStatsTimer()
    }

    // MARK: Stats (reader-stats design)

    /// Recomputes the panel and line from the live session, the baselines and time left.
    func refreshStats() {
        let isReady: Bool
        if case .ready = state { isReady = true } else { isReady = false }
        let input = ReaderStatsInput(
            live: tracker.liveStats(),
            baseline: statsBaseline,
            timeLeft: timeLeft,
            bookProgression: isReady ? currentProgression : nil,
            isScrollMode: preferences.scroll == true,
            hasWordIndex: tracker.wordIndex != nil && !isFixedLayout
        )
        let panel = ReaderStatsCalculator.values(statsSettings.panel, input: input)
        let line = reservesStatsLine && statsSettings.lineEnabled
            ? ReaderStatsCalculator.values(statsSettings.line, input: input, style: .compact)
            : []
        if panel != panelStats { panelStats = panel }
        if line != lineStats { lineStats = line }
    }

    /// Usual pace, today's finished minutes and the goal: on open, when a session row lands, and
    /// on chapter change (which also picks up a new reading day).
    private func reloadStatsBaseline() {
        guard !isClosed else { return }
        let database = database, bookID = bookID
        baselineTask?.cancel()
        baselineTask = Task { [weak self] in
            let baseline = try? await database.reader.read { db in
                try MetricsQueries.readerStatsBaseline(db, bookID: bookID)
            }
            guard !Task.isCancelled, let self else { return }
            statsBaseline = baseline
            refreshStats()
        }
    }

    /// Ticks the session timer: every second while the panel is up, every 15 s for the line.
    private func updateStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
        let interval: Duration
        if isChromeVisible {
            interval = .seconds(1)
        } else if reservesStatsLine && statsSettings.lineEnabled {
            interval = .seconds(15)
        } else {
            return
        }
        guard !isClosed else { return }
        statsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.refreshStats()
            }
        }
    }

    // MARK: Location

    /// Called by the navigator delegate; saves the resume point after 2 s without further moves.
    func locationDidChange(_ locator: Locator) {
        updateLocationInfo(locator)
        let kind = classifyLocationChange()
        tracker.location(locator, kind: kind)
        refreshStats()

        if revealsInitialTarget {
            revealsInitialTarget = false
            Task { [weak self] in
                // This change is already classified; the nudge reports its own 0.3 s later.
                if await self?.host?.revealScrolledTarget() == true {
                    self?.markNextLocationAsJump()
                }
            }
        }

        if holdsResumePoint {
            // Opened at a highlight: keep the saved position until the reader actually reads on.
            guard kind != .jump else { return }
            holdsResumePoint = false
        }
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
        currentLocator = locator
        refreshTimeLeft(locator)
        if let href = currentHref, href != baselineChapterHref, baselineChapterHref != nil {
            reloadStatsBaseline()
        }
        baselineChapterHref = currentHref
    }

    /// Recomputes time left from the word index and the book pace, coalescing rapid page turns.
    /// Fixed-layout books have no word counts, so they show none.
    private func refreshTimeLeft(_ locator: Locator) {
        guard !isFixedLayout, let index = tracker.wordIndex else { return }
        let href = HrefKey.key(locator.href)
        guard let wordIdx = index.wordIdx(href: href, progression: locator.locations.progression ?? 0) else { return }
        let chapterID = index.chapterID(href: href)
        let bookID = bookID
        let database = database
        timeLeftTask?.cancel()
        timeLeftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = try? await database.reader.read { db in
                try MetricsQueries.timeLeft(db, bookID: bookID, chapterID: chapterID, currentWordIdx: wordIdx,
                                            today: try MetricsQueries.today(db))
            }
            guard !Task.isCancelled else { return }
            self?.timeLeft = result
            self?.refreshStats()
        }
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
            guard await host.go(to: locator) else { return false }
            if preferences.scroll == true, locator.text.highlight != nil {
                // Readium reports the location 0.3 s after the last scroll, so the jump and this
                // nudge arrive as one change, already classified as a jump by `didJumpToLink`.
                await host.revealScrolledTarget()
            }
            return true
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

    // MARK: Highlights (SPEC §7)

    /// Observes the book's highlights and bookmarks. Every highlight change re-applies the full
    /// decoration list on the main actor (Highlights guide), so creating, recoloring and
    /// deleting all go through the database.
    private func startObserving() {
        let bookID = bookID
        let reader = database.reader
        observationTasks.append(Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try HighlightRequests.highlights(bookID: bookID).fetchAll(db)
            }
            do {
                for try await rows in observation.values(in: reader) {
                    guard let self else { return }
                    highlights = rows
                    host?.applyHighlightDecorations(HighlightCapture.decorations(for: rows))
                }
            } catch {
                // Observation failed; decorations stay as last applied.
            }
        })
        observationTasks.append(Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try BookmarkRequests.bookmarks(bookID: bookID).fetchAll(db)
            }
            do {
                for try await rows in observation.values(in: reader) {
                    guard let self else { return }
                    bookmarks = rows
                }
            } catch {}
        })
        observationTasks.append(Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try MetricsQueries.readerStatsSettings(db)
            }.removeDuplicates()
            do {
                for try await settings in observation.values(in: reader) {
                    guard let self else { return }
                    statsSettings = settings
                    refreshStats()
                    updateStatsTimer()
                }
            } catch {}
        })
    }

    /// Selection menu: saves a highlight in the last-used color, then optionally opens the editor.
    func createHighlight(from locator: Locator, openEditor focus: HighlightEditorFocus?) {
        guard let publication else { return }
        let color = lastHighlightColor
        Task {
            let text = await chapterText(for: locator, in: publication)
            guard let new = HighlightCapture.newHighlight(
                bookID: bookID, locator: locator, chapterText: text,
                wordIndex: tracker.wordIndex, color: color
            ) else { return }
            do {
                let saved = try await database.saveHighlight(new)
                if let focus {
                    editingHighlight = HighlightEditorTarget(id: saved.id, focus: focus)
                }
            } catch {
                actionError = "The highlight couldn't be saved. \(error.localizedDescription)"
            }
        }
    }

    private func chapterText(for locator: Locator, in publication: Publication) async -> String? {
        let key = HrefKey.key(locator.href)
        if let cached = chapterTexts[key] { return cached }
        let text = await HighlightCapture.chapterText(of: publication, href: locator.href)
        if let text { chapterTexts[key] = text }
        return text
    }

    /// Navigator decoration tap.
    func didTapHighlight(id: String) {
        editingHighlight = HighlightEditorTarget(id: id, focus: nil)
    }

    /// The editor picked a color: it becomes the color for the next quick Highlight.
    func rememberHighlightColor(_ color: HighlightColor) {
        lastHighlightColor = color
        let database = database
        Task { try? await database.setLastHighlightColor(color) }
    }

    @discardableResult
    func go(toStoredLocator json: String?) async -> Bool {
        guard let locator = Locator(storedJSONString: json) else { return false }
        return await go(to: .locator(locator))
    }

    // MARK: Bookmarks

    /// Max progression difference (within one resource) for "this page is bookmarked".
    static let bookmarkTolerance = 0.005

    /// The bookmark on the current page, if any.
    var currentBookmark: BookmarkRecord? {
        guard let locator = currentLocator else { return nil }
        let href = HrefKey.key(locator.href)
        let progression = locator.locations.progression ?? 0
        return bookmarks.first {
            $0.spineHref == href && abs(($0.progression ?? -1) - progression) < Self.bookmarkTolerance
        }
    }

    /// Adds a bookmark at the current location, or removes the one on this page.
    func toggleBookmark() async {
        do {
            if let existing = currentBookmark {
                try await database.softDeleteBookmark(id: existing.id)
            } else if let locator = currentLocator, let json = locator.storedJSONString {
                let percent = Int(((locator.locations.totalProgression ?? 0) * 100).rounded())
                let label = [locator.title, "\(percent)%"].compactMap { $0 }.joined(separator: " · ")
                try await database.addBookmark(NewBookmark(
                    bookID: bookID,
                    spineHref: HrefKey.key(locator.href),
                    progression: locator.locations.progression,
                    locatorJSON: json,
                    totalProgression: locator.locations.totalProgression,
                    label: label
                ))
            }
        } catch {
            actionError = "The bookmark couldn't be saved. \(error.localizedDescription)"
        }
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
        refreshStats()
    }

    /// Back in the foreground after `didEnterBackground()` (no-op otherwise).
    func didBecomeActive() {
        tracker.foreground()
        refreshStats()
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
        observationTasks.forEach { $0.cancel() }
        observationTasks = []
        statsTimer?.cancel()
        statsTimer = nil
        baselineTask?.cancel()
        // Ends the session and waits for its writes before the publication goes away.
        tracker.onSessionEnded = nil
        await tracker.close()
        await flush()
        publication?.close()
        publication = nil
        // The session just ended: refresh the widget within seconds (PLAN M6).
        await widgets.publish()
    }
}
