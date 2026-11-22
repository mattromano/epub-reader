import Foundation

/// The session state machine (SPEC §6.1–6.2). Pure and deterministic given `(event, date)`
/// (apart from the UUIDs it mints for session and event ids); `Codable` so its state can be
/// checkpointed to `session_draft.state_json`.
///
/// States: `idle` (no book) → `reading` on `.open`; `reading` → `paused` on `.background` or
/// when a `.tick` / `.location` finds no activity for more than `idleThreshold`; `paused` →
/// `reading` on `.foreground` / `.location` within `sessionGap` of the pause time, otherwise the
/// session ends at the pause time and a new one starts. After a session ends while the book is
/// still open the tracker is `dormant`: the next `.foreground` / `.location` starts a new session.
public struct SessionTracker: Codable, Sendable {
    public private(set) var config: TrackerConfig

    /// Book context from the last `.open` (kept across sessions until `.close`).
    var context: SessionContext?
    var phase: Phase = .idle
    var session: ActiveSession?

    enum Phase: String, Codable, Sendable {
        /// No book open.
        case idle
        /// Book open, session in progress and active.
        case reading
        /// Book open, session in progress but paused (see `ActiveSession.pause`).
        case paused
        /// Book open, no session (the previous one ended after a long pause).
        case dormant
    }

    enum PauseCause: String, Codable, Sendable {
        case background
        case idle
    }

    struct Pause: Codable, Sendable {
        var at: Date
        var cause: PauseCause
    }

    /// Running totals of the session in progress.
    struct ActiveSession: Codable, Sendable {
        var sessionID: String
        var startedAt: Date
        var localDate: String
        var localStartHour: Int
        var tzOffsetMinutes: Int

        var activeSeconds: Double = 0
        /// Capped gaps between consecutive emitted location rows (for the median tail).
        var gaps: [Double] = []
        /// Last activity (open, resume, or any location sample incl. throttled scrolls).
        var lastActivityAt: Date
        /// Start of the next median gap; nil right after open/resume.
        var gapAnchorAt: Date?
        /// Time and total progression of the last emitted location row (throttle + seconds_since_prev).
        var lastLocationRowAt: Date?
        var lastLocationTotalProgression: Double?
        /// Last location seen, used to fill pause/resume/close rows.
        var lastSample: LocationSample?

        var seeded = false
        var prevWordIdx: Int?
        var countedDeltas: [Int] = []
        var wordsRead = 0
        var pageTurns = 0
        var scrollEvents = 0
        var jumpCount = 0
        var anyIndexed = false
        var startWordIdx: Int?
        var endWordIdx: Int?
        var startTotalProgression: Double?
        var endTotalProgression: Double?
        var startLocatorJSON: String?
        var endLocatorJSON: String?

        var lastCheckpointAt: Date
        var pause: Pause?
    }

    public init(config: TrackerConfig) {
        self.config = config
    }

    /// Id of the session in progress, if any.
    public var currentSessionID: String? { session?.sessionID }

    // MARK: - Events

    /// Feeds one event at `date`; returns rows to persist, in order.
    public mutating func handle(_ event: TrackerEvent, at date: Date) -> [TrackerOutput] {
        var out: [TrackerOutput] = []
        switch event {
        case .open(let ctx):
            if session != nil {
                out += endSession(at: date, reason: .bookSwitched)
            }
            context = ctx
            startSession(at: date)

        case .location(let sample):
            guard context != nil else { return [] }
            switch phase {
            case .idle:
                return []
            case .dormant:
                startSession(at: date)
            case .reading:
                if isIdle(at: date) {
                    out += pauseSession(at: idlePauseTime(), cause: .idle)
                }
            case .paused:
                break
            }
            if phase == .paused {
                out += resumeOrRestart(at: date)
            }
            out += handleLocation(sample, at: date)

        case .background:
            switch phase {
            case .reading:
                if isIdle(at: date) {
                    out += pauseSession(at: idlePauseTime(), cause: .idle)
                } else {
                    out += pauseSession(at: date, cause: .background)
                }
            case .paused:
                // Already paused (idle); refresh the checkpoint so a kill in background recovers.
                if let draft = makeCheckpoint(at: session!.pause!.at) { out.append(.checkpoint(draft)) }
            case .idle, .dormant:
                break
            }

        case .foreground:
            switch phase {
            case .paused:
                out += resumeOrRestart(at: date)
            case .dormant:
                startSession(at: date)
            case .idle, .reading:
                break
            }

        case .tick:
            switch phase {
            case .reading:
                if isIdle(at: date) {
                    out += pauseSession(at: idlePauseTime(), cause: .idle)
                } else if date.timeIntervalSince(session!.lastCheckpointAt) >= config.checkpointInterval,
                          let draft = makeCheckpoint(at: date) {
                    out.append(.checkpoint(draft))
                }
            case .paused:
                if date.timeIntervalSince(session!.pause!.at) > config.sessionGap {
                    out += endSession(at: date, reason: endReasonForPause())
                }
            case .idle, .dormant:
                break
            }

        case .close:
            if session != nil {
                if phase == .reading, isIdle(at: date) {
                    out += pauseSession(at: idlePauseTime(), cause: .idle)
                }
                if phase == .paused, date.timeIntervalSince(session!.pause!.at) > config.sessionGap {
                    out += endSession(at: date, reason: endReasonForPause())
                } else {
                    out.append(.locationEvent(controlRow(.close, at: date)))
                    out += endSession(at: date, reason: .closed)
                }
            }
            context = nil
            phase = .idle

        case .contextChanged(let readingMode, let fontSize):
            context?.readingMode = readingMode
            context?.fontSize = fontSize
        }
        return out
    }

    // MARK: - Session lifecycle

    private mutating func startSession(at date: Date) {
        let tz = config.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        session = ActiveSession(
            sessionID: UUID().uuidString,
            startedAt: date,
            localDate: ReadingDay.localDate(for: date, timeZone: tz, dayStartHour: config.dayStartHour),
            localStartHour: calendar.component(.hour, from: date),
            tzOffsetMinutes: tz.secondsFromGMT(for: date) / 60,
            lastActivityAt: date,
            lastCheckpointAt: date)
        phase = .reading
    }

    private func isIdle(at date: Date) -> Bool {
        guard let session else { return false }
        return date.timeIntervalSince(session.lastActivityAt) > config.idleThreshold
    }

    /// For an idle pause: last activity plus the tail.
    private func idlePauseTime() -> Date {
        let s = session!
        return s.lastActivityAt.addingTimeInterval(tail(endingAt: .distantFuture))
    }

    /// min(time since last activity, median gap so far; 0 if none).
    private func tail(endingAt end: Date) -> Double {
        guard let s = session else { return 0 }
        let since = max(0, end.timeIntervalSince(s.lastActivityAt))
        return min(since, Self.median(s.gaps))
    }

    private mutating func pauseSession(at pauseAt: Date, cause: PauseCause) -> [TrackerOutput] {
        guard phase == .reading, session != nil else { return [] }
        session!.activeSeconds += tail(endingAt: pauseAt)
        session!.pause = Pause(at: pauseAt, cause: cause)
        phase = .paused
        var out: [TrackerOutput] = [.locationEvent(controlRow(.pause, at: pauseAt))]
        if let draft = makeCheckpoint(at: pauseAt) { out.append(.checkpoint(draft)) }
        return out
    }

    /// From `.paused`: continue within `sessionGap`, otherwise end the old session at the pause
    /// time and start a new one at `date`.
    private mutating func resumeOrRestart(at date: Date) -> [TrackerOutput] {
        guard phase == .paused, let pause = session?.pause else { return [] }
        if date.timeIntervalSince(pause.at) <= config.sessionGap {
            session!.pause = nil
            session!.lastActivityAt = date
            session!.gapAnchorAt = nil
            phase = .reading
            return [.locationEvent(controlRow(.resume, at: date))]
        }
        let out = endSession(at: date, reason: endReasonForPause())
        startSession(at: date)
        return out
    }

    private func endReasonForPause() -> EndReason {
        session?.pause?.cause == .background ? .backgrounded : .idleTimeout
    }

    /// Ends the current session (`ended_at` = the pause time if paused, else `date` plus tail
    /// accounting) and emits `.sessionEnded` or `.sessionDiscarded`.
    private mutating func endSession(at date: Date, reason: EndReason) -> [TrackerOutput] {
        guard session != nil else { return [] }
        let endedAt: Date
        if let pause = session!.pause {
            endedAt = pause.at
        } else {
            session!.activeSeconds += tail(endingAt: date)
            endedAt = date
        }
        let sessionID = session!.sessionID
        let result = finalize(endedAt: endedAt, reason: reason)
        session = nil
        phase = context == nil ? .idle : .dormant
        if let row = result {
            return [.sessionEnded(row)]
        }
        return [.sessionDiscarded(sessionID: sessionID)]
    }

    /// Builds the session row from the running totals (tail must already be applied).
    /// Returns nil when the discard rule fails.
    private func finalize(endedAt: Date, reason: EndReason) -> SessionRow? {
        guard let s = session, let ctx = context else { return nil }
        let activityEvents = s.pageTurns + s.scrollEvents
        guard s.activeSeconds >= config.minActiveSeconds, activityEvents > 0 else { return nil }
        let eligible = !ctx.isFixedLayout && s.anyIndexed && s.activeSeconds >= 60 && s.wordsRead >= 50
        return SessionRow(
            sessionID: s.sessionID, bookID: ctx.bookID, deviceID: ctx.deviceID,
            startedAt: s.startedAt, endedAt: endedAt,
            localDate: s.localDate, localStartHour: s.localStartHour, tzOffsetMinutes: s.tzOffsetMinutes,
            wallSeconds: endedAt.timeIntervalSince(s.startedAt), activeSeconds: s.activeSeconds,
            startWordIdx: s.startWordIdx, endWordIdx: s.endWordIdx, wordsRead: s.wordsRead,
            startTotalProgression: s.startTotalProgression, endTotalProgression: s.endTotalProgression,
            startLocatorJSON: s.startLocatorJSON, endLocatorJSON: s.endLocatorJSON,
            pageTurns: s.pageTurns, jumpCount: s.jumpCount,
            readingMode: ctx.readingMode, fontSize: ctx.fontSize,
            endReason: reason, isPaceEligible: eligible)
    }

    // MARK: - Locations and words

    private mutating func handleLocation(_ sample: LocationSample, at date: Date) -> [TrackerOutput] {
        guard phase == .reading, var s = session else { return [] }
        defer { session = s }

        // Activity: advances the idle clock and active time, even for a throttled scroll.
        let gap = min(max(0, date.timeIntervalSince(s.lastActivityAt)), config.idleThreshold)
        s.activeSeconds += gap
        s.lastActivityAt = date

        let secondsSincePrev = s.lastLocationRowAt.map { date.timeIntervalSince($0) }

        if !s.seeded {
            s.seeded = true
            s.prevWordIdx = sample.wordIdx
            s.gapAnchorAt = date
            noteLocation(sample, at: date, in: &s)
            return [.locationEvent(row(sample, type: .open, at: date, wordsDelta: nil,
                                       secondsSincePrev: secondsSincePrev, isCounted: false, session: s))]
        }

        if sample.kind == .scroll, let lastAt = s.lastLocationRowAt {
            let tooSoon = date.timeIntervalSince(lastAt) < config.scrollMinInterval
            var tooSmall = false
            if let prev = s.lastLocationTotalProgression, let now = sample.totalProgression {
                tooSmall = abs(now - prev) < config.scrollMinProgressionDelta
            }
            if tooSoon || tooSmall { return [] }
        }

        var delta: Int?
        if let w = sample.wordIdx, let prev = s.prevWordIdx { delta = w - prev }
        var counted = false

        switch sample.kind {
        case .jump:
            s.jumpCount += 1
            s.prevWordIdx = sample.wordIdx
        case .pageTurn, .scroll:
            if sample.kind == .pageTurn { s.pageTurns += 1 } else { s.scrollEvents += 1 }
            if let d = delta {
                let cap = max(config.minWordCap, 5 * Self.p95(s.countedDeltas))
                if d > cap {
                    s.jumpCount += 1
                } else if d > 0 {
                    let seconds = secondsSincePrev ?? 0
                    let overRate = seconds <= 0 || Double(d) / (seconds / 60) > config.maxWordsPerMinute
                    if !overRate {
                        counted = true
                        s.wordsRead += d
                        s.countedDeltas.append(d)
                    }
                }
            }
            if sample.wordIdx != nil || s.prevWordIdx == nil {
                s.prevWordIdx = sample.wordIdx
            }
        }

        if let anchor = s.gapAnchorAt {
            s.gaps.append(min(max(0, date.timeIntervalSince(anchor)), config.idleThreshold))
        }
        s.gapAnchorAt = date
        noteLocation(sample, at: date, in: &s)
        return [.locationEvent(row(sample, type: LocationEventType(sample.kind), at: date, wordsDelta: delta,
                                   secondsSincePrev: secondsSincePrev, isCounted: counted, session: s))]
    }

    /// Updates start/end snapshots and throttle references for an emitted location row.
    private func noteLocation(_ sample: LocationSample, at date: Date, in s: inout ActiveSession) {
        s.lastLocationRowAt = date
        s.lastLocationTotalProgression = sample.totalProgression
        s.lastSample = sample
        if let w = sample.wordIdx {
            s.anyIndexed = true
            if s.startWordIdx == nil { s.startWordIdx = w }
            s.endWordIdx = w
        }
        if s.startTotalProgression == nil { s.startTotalProgression = sample.totalProgression }
        if sample.totalProgression != nil { s.endTotalProgression = sample.totalProgression }
        if s.startLocatorJSON == nil { s.startLocatorJSON = sample.locatorJSON }
        if sample.locatorJSON != nil { s.endLocatorJSON = sample.locatorJSON }
    }

    private func row(_ sample: LocationSample, type: LocationEventType, at date: Date, wordsDelta: Int?,
                     secondsSincePrev: Double?, isCounted: Bool, session s: ActiveSession) -> LocationEventRow {
        LocationEventRow(
            eventID: UUID().uuidString, sessionID: s.sessionID, bookID: context?.bookID ?? "",
            occurredAt: date, eventType: type, chapterID: sample.chapterID,
            progression: sample.progression, totalProgression: sample.totalProgression,
            wordIdx: sample.wordIdx, wordsDelta: wordsDelta, secondsSincePrev: secondsSincePrev,
            isCounted: isCounted, locatorJSON: sample.locatorJSON)
    }

    /// pause / resume / close rows: carry the last known location, never counted.
    private func controlRow(_ type: LocationEventType, at date: Date) -> LocationEventRow {
        let s = session!
        let last = s.lastSample
        return LocationEventRow(
            eventID: UUID().uuidString, sessionID: s.sessionID, bookID: context?.bookID ?? "",
            occurredAt: date, eventType: type, chapterID: last?.chapterID,
            progression: last?.progression, totalProgression: last?.totalProgression,
            wordIdx: last?.wordIdx, wordsDelta: nil,
            secondsSincePrev: s.lastLocationRowAt.map { date.timeIntervalSince($0) },
            isCounted: false, locatorJSON: last?.locatorJSON)
    }

    // MARK: - Checkpoint and recovery

    private mutating func makeCheckpoint(at date: Date) -> SessionDraft? {
        guard session != nil, let ctx = context else { return nil }
        session!.lastCheckpointAt = date
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return SessionDraft(sessionID: session!.sessionID, bookID: ctx.bookID,
                            startedAt: session!.startedAt, lastCheckpointAt: date, stateJSON: json)
    }

    /// Finalizes a checkpointed draft after a crash or kill: ends at `draft.lastCheckpointAt`
    /// with `.crashRecovered`. Returns nil when the session fails the discard rule (or the
    /// state can't be decoded).
    public static func recover(_ draft: SessionDraft) -> SessionRow? {
        guard let data = draft.stateJSON.data(using: .utf8),
              var tracker = try? JSONDecoder().decode(SessionTracker.self, from: data),
              tracker.session != nil, tracker.context != nil else { return nil }
        let end = draft.lastCheckpointAt
        if tracker.phase == .reading {
            // A paused session already had its tail applied at pause time.
            tracker.session!.activeSeconds += tracker.tail(endingAt: end)
        }
        return tracker.finalize(endedAt: end, reason: .crashRecovered)
    }

    // MARK: - Stats helpers

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Nearest-rank 95th percentile; 0 when empty.
    static func p95(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}

extension LocationEventType {
    init(_ kind: LocationKind) {
        switch kind {
        case .pageTurn: self = .pageTurn
        case .scroll: self = .scroll
        case .jump: self = .jump
        }
    }
}

/// Reading-day math (SPEC §5 conventions): computed in Swift at write time, never in SQL.
public enum ReadingDay {
    /// 'YYYY-MM-DD' of the reading day containing `date`: local time minus `dayStartHour` hours.
    public static func localDate(for date: Date, timeZone: TimeZone, dayStartHour: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let shifted = date.addingTimeInterval(-Double(dayStartHour) * 3600)
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
