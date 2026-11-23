import Foundation
import Importing
import Persistence
@preconcurrency import ReadiumShared
import Tracking

/// Feeds the pure `SessionTracker` (SPEC §6.1–6.2) from the reader and persists what it emits.
///
/// - Owns the tracker, the 30 s checkpoint timer and the `WordIndex` lookup, so
///   `ReaderViewModel` only classifies location changes.
/// - Every DB write goes through one serial chain, so writes land in the order the tracker
///   emitted them: a checkpoint never lands after `finishSession`, an append never after
///   `discardSession`. The chain is never cancelled (GRDB abandons writes from cancelled tasks).
@MainActor
final class TrackerDriver {
    private let database: AppDatabase
    private let bookID: String
    private let clock: any Clock

    private var tracker = SessionTracker(config: TrackerConfig())
    /// Loaded by `prepare()`; nil while the book is still indexing (or fixed layout).
    private(set) var wordIndex: WordIndex?
    private var writeChain: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var isStarted = false
    private var isClosed = false
    private var isBackgrounded = false
    /// Called on the main actor once a finished session row has been written (the reader
    /// reloads its stats baselines).
    var onSessionEnded: (() -> Void)?

    init(database: AppDatabase, bookID: String, clock: any Clock = SystemClock()) {
        self.database = database
        self.bookID = bookID
        self.clock = clock
    }

    /// Loads the thresholds and the book's word index. Call before `start(context:)`.
    /// A book that's still indexing has no index yet: its samples carry no `wordIdx`.
    func prepare() async {
        let config = (try? await database.trackerConfig()) ?? TrackerConfig()
        tracker = SessionTracker(config: config)
        wordIndex = try? await database.loadWordIndex(bookID: bookID)
    }

    /// Starts the session (`.open`) and the checkpoint timer. No-op once started or closed.
    func start(context: SessionContext) {
        guard !isStarted, !isClosed else { return }
        isStarted = true
        send(.open(context))
        startTicking()
    }

    /// One navigator location change, already classified by the caller.
    func location(_ locator: Locator, kind: LocationKind) {
        let href = HrefKey.key(locator.href)
        let progression = locator.locations.progression
        let sample = LocationSample(
            kind: kind,
            wordIdx: wordIndex?.wordIdx(href: href, progression: progression ?? 0),
            chapterID: wordIndex?.chapterID(href: href),
            progression: progression,
            totalProgression: locator.locations.totalProgression,
            locatorJSON: locator.storedJSONString
        )
        send(.location(sample))
    }

    func background() {
        guard isStarted, !isClosed, !isBackgrounded else { return }
        isBackgrounded = true
        send(.background)
    }

    /// Only after `background()`: `.inactive → .active` (Control Center, alerts) isn't a resume.
    func foreground() {
        guard isBackgrounded else { return }
        isBackgrounded = false
        send(.foreground)
    }

    func contextChanged(readingMode: String, fontSize: Double?) {
        send(.contextChanged(readingMode: readingMode, fontSize: fontSize))
    }

    /// Ends the session and waits until every write (including the finished session) has
    /// landed, so the caller can close the publication afterwards. Safe to call more than once.
    func close() async {
        if !isClosed {
            if isStarted {
                send(.close)
            }
            isClosed = true
            tickTask?.cancel()
            tickTask = nil
        }
        await writeChain?.value
    }

    /// The session in progress right now, for the reader's live stats; nil when none.
    func liveStats() -> LiveSessionStats? {
        guard isStarted, !isClosed else { return nil }
        return tracker.live(at: clock.now())
    }

    // MARK: - Private

    private func send(_ event: TrackerEvent) {
        guard isStarted, !isClosed else { return }
        persist(tracker.handle(event, at: clock.now()))
    }

    private func startTicking() {
        let interval = tracker.config.checkpointInterval
        guard interval > 0 else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// The sleep can run out during suspension and fire on resume before `foreground()`;
    /// a backgrounded session was already checkpointed, and `.foreground` settles it.
    private func tick() {
        guard !isBackgrounded else { return }
        send(.tick)
    }

    /// Maps outputs to DB writes, batching consecutive location events into one append.
    private func persist(_ outputs: [TrackerOutput]) {
        var pendingEvents: [LocationEventRow] = []
        for output in outputs {
            if case let .locationEvent(row) = output {
                pendingEvents.append(row)
                continue
            }
            if !pendingEvents.isEmpty {
                enqueueAppend(pendingEvents)
                pendingEvents = []
            }
            switch output {
            case .locationEvent:
                break // handled above
            case let .checkpoint(draft):
                enqueueWrite { try await $0.saveCheckpoint(draft) }
            case let .sessionEnded(row):
                enqueueWrite { try await $0.finishSession(row) }
                notifySessionEndedAfterWrites()
            case let .sessionDiscarded(sessionID):
                enqueueWrite { try await $0.discardSession(id: sessionID) }
            }
        }
        if !pendingEvents.isEmpty {
            enqueueAppend(pendingEvents)
        }
    }

    /// Runs `onSessionEnded` once every write queued so far has landed.
    private func notifySessionEndedAfterWrites() {
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            self?.onSessionEnded?()
        }
    }

    private func enqueueAppend(_ rows: [LocationEventRow]) {
        enqueueWrite { try await $0.appendLocationEvents(rows) }
    }

    /// Appends one write to the serial chain. A failed write is dropped (crash recovery and the
    /// next checkpoint cover it) so the chain keeps going.
    private func enqueueWrite(_ write: @escaping @Sendable (AppDatabase) async throws -> Void) {
        let previous = writeChain
        let database = database
        writeChain = Task {
            await previous?.value
            do {
                try await write(database)
            } catch {
                // Best effort; see above.
            }
        }
    }
}
