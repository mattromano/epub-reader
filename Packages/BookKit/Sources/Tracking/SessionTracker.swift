import Foundation

/// The session state machine (SPEC §6.1–6.2). Pure and deterministic given `(event, date)`;
/// `Codable` so its state can be checkpointed to `session_draft.state_json`.
///
/// SCAFFOLD STUB — Agent B implements. Public signatures are the contract.
public struct SessionTracker: Codable, Sendable {
    public private(set) var config: TrackerConfig

    public init(config: TrackerConfig) {
        self.config = config
    }

    /// Feeds one event at `date`; returns rows to persist, in order.
    public mutating func handle(_ event: TrackerEvent, at date: Date) -> [TrackerOutput] {
        []
    }

    /// Id of the session in progress, if any.
    public var currentSessionID: String? { nil }

    /// Finalizes a checkpointed draft after a crash or kill: ends at `draft.lastCheckpointAt`
    /// with `.crashRecovered`. Returns nil when the session fails the discard rule (or the
    /// state can't be decoded).
    public static func recover(_ draft: SessionDraft) -> SessionRow? {
        nil
    }
}

/// Reading-day math (SPEC §5 conventions): computed in Swift at write time, never in SQL.
public enum ReadingDay {
    /// 'YYYY-MM-DD' of the reading day containing `date`: local time minus `dayStartHour` hours.
    /// SCAFFOLD STUB — Agent B implements.
    public static func localDate(for date: Date, timeZone: TimeZone, dayStartHour: Int) -> String {
        ""
    }
}
