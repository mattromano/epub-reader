import Foundation
import Tracking

/// What the widget shows, written by the app as `widget_snapshot.json` in the App Group
/// container (PLAN M6). A file instead of the database, so the widget process never holds a
/// SQLite lock. Pure value type: no UIKit, no GRDB.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let fileName = "widget_snapshot.json"

    public struct ContinueReading: Codable, Sendable, Equatable {
        public var bookID: String
        public var title: String
        public var authors: String
        /// Relative to the App Group container (`Covers/<sha>.jpg`).
        public var coverRelpath: String?
        public var percentComplete: Double?
        public var bookMinutesLeft: Double?

        public init(bookID: String, title: String, authors: String, coverRelpath: String?,
                    percentComplete: Double?, bookMinutesLeft: Double?) {
            self.bookID = bookID
            self.title = title
            self.authors = authors
            self.coverRelpath = coverRelpath
            self.percentComplete = percentComplete
            self.bookMinutesLeft = bookMinutesLeft
        }
    }

    public var generatedAt: Date
    /// Reading day (`local_date`) the numbers below belong to.
    public var today: String
    public var dayStartHour: Int
    public var timeZoneID: String
    public var todayMinutes: Double
    public var goalMinutes: Double?
    public var streakMinMinutes: Double
    public var currentStreak: Int
    /// True when `today` already qualifies and is counted in `currentStreak`.
    public var streakIncludesToday: Bool
    public var continueReading: ContinueReading?

    public init(generatedAt: Date, today: String, dayStartHour: Int, timeZoneID: String, todayMinutes: Double,
                goalMinutes: Double?, streakMinMinutes: Double, currentStreak: Int, streakIncludesToday: Bool,
                continueReading: ContinueReading?) {
        self.generatedAt = generatedAt
        self.today = today
        self.dayStartHour = dayStartHour
        self.timeZoneID = timeZoneID
        self.todayMinutes = todayMinutes
        self.goalMinutes = goalMinutes
        self.streakMinMinutes = streakMinMinutes
        self.currentStreak = currentStreak
        self.streakIncludesToday = streakIncludesToday
        self.continueReading = continueReading
    }

    private var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    // MARK: Display

    /// The snapshot as of `now`. If the reading day rolled over since it was written, today's
    /// minutes reset and the streak follows the "alive through yesterday" rule (SPEC §6.3).
    public func display(at now: Date) -> WidgetDisplayState {
        let current = ReadingDay.localDate(for: now, timeZone: timeZone, dayStartHour: dayStartHour)
        let minutes: Double
        let streak: Int
        let atRisk: Bool
        if current == today {
            minutes = todayMinutes
            streak = currentStreak
            atRisk = currentStreak > 0 && !streakIncludesToday
        } else if current == Self.dayAfter(today) {
            minutes = 0
            // Yesterday (the snapshot day) must have qualified for the streak to survive.
            streak = streakIncludesToday ? currentStreak : 0
            atRisk = streak > 0
        } else {
            minutes = 0
            streak = 0
            atRisk = false
        }
        let progress = goalMinutes.flatMap { $0 > 0 ? min(minutes / $0, 1) : nil }
        return WidgetDisplayState(todayMinutes: minutes, goalMinutes: goalMinutes, goalProgress: progress,
                                  currentStreak: streak, streakIsAtRisk: atRisk, continueReading: continueReading)
    }

    /// When the next reading day starts: local midnight of the current reading day's date, plus
    /// a day, plus `dayStartHour` hours (the same rule as the aggregates' day windows).
    public func nextDayStart(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shifted = now.addingTimeInterval(-Double(dayStartHour) * 3600)
        let midnight = calendar.startOfDay(for: shifted)
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(86_400)
        return nextMidnight.addingTimeInterval(Double(dayStartHour) * 3600)
    }

    private static func dayAfter(_ localDate: String) -> String? {
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let base = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let next = calendar.date(byAdding: .day, value: 1, to: base) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: next)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: File

    /// Nil when there's no file yet or it can't be decoded (the widget then shows a placeholder).
    public static func read(from containerURL: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: containerURL.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Atomic write, so the widget never reads a half-written file.
    public func write(to containerURL: URL) throws {
        let data = try Self.encoder.encode(self)
        try data.write(to: containerURL.appendingPathComponent(Self.fileName), options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// What the widget draws at a given moment.
public struct WidgetDisplayState: Sendable, Equatable {
    public var todayMinutes: Double
    public var goalMinutes: Double?
    /// 0–1, nil without a goal.
    public var goalProgress: Double?
    public var currentStreak: Int
    /// The streak is alive but today hasn't qualified yet.
    public var streakIsAtRisk: Bool
    public var continueReading: WidgetSnapshot.ContinueReading?

    public init(todayMinutes: Double, goalMinutes: Double?, goalProgress: Double?, currentStreak: Int,
                streakIsAtRisk: Bool, continueReading: WidgetSnapshot.ContinueReading?) {
        self.todayMinutes = todayMinutes
        self.goalMinutes = goalMinutes
        self.goalProgress = goalProgress
        self.currentStreak = currentStreak
        self.streakIsAtRisk = streakIsAtRisk
        self.continueReading = continueReading
    }
}

/// `margins://open?book=<id>`: the widget's deep link into the reader at the last position.
public enum WidgetLink {
    public static let scheme = "margins"

    public static func openBook(_ bookID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "book", value: bookID)]
        return components.url!
    }

    public static func bookID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "book" }?.value
    }
}
