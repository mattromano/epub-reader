import Foundation
import Tracking

/// Reading-day calendar math, done in Swift so SQL never does timezone math (CLAUDE.md).
/// A reading day `YYYY-MM-DD` runs from local midnight + `dayStartHour` h on that date to local
/// midnight + `dayStartHour` h on the next date (the `ReadingDay.localDate` rule).
public enum ReadingDays {
    public static let defaultDayStartHour = 4

    /// The reading day containing `now`.
    public static func today(now: Date = Date(), dayStartHour: Int, timeZone: TimeZone) -> String {
        ReadingDay.localDate(for: now, timeZone: timeZone, dayStartHour: dayStartHour)
    }

    /// `localDate` shifted by `days` calendar days (date arithmetic only, no time zone).
    /// Returns nil for a malformed date string.
    public static func adding(_ days: Int, to localDate: String) -> String? {
        guard let comps = components(localDate),
              let base = utcCalendar.date(from: comps),
              let shifted = utcCalendar.date(byAdding: .day, value: days, to: base) else { return nil }
        let c = utcCalendar.dateComponents([.year, .month, .day], from: shifted)
        return format(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    /// The UTC timestamp strings bounding a reading day: `[start, end)`, in the stored
    /// `Timestamp` format, so SQL can compare `created_at` / `finished_at` as plain strings.
    public static func window(for localDate: String, dayStartHour: Int,
                              timeZone: TimeZone) -> (start: String, end: String)? {
        guard let start = startInstant(of: localDate, dayStartHour: dayStartHour, timeZone: timeZone),
              let next = adding(1, to: localDate),
              let end = startInstant(of: next, dayStartHour: dayStartHour, timeZone: timeZone) else { return nil }
        return (Timestamp.string(from: start), Timestamp.string(from: end))
    }

    /// The UTC instant a reading day starts: local midnight of `localDate` plus `dayStartHour`
    /// hours of elapsed time. This is the exact inverse of `ReadingDay.localDate` (local date of
    /// `instant − dayStartHour h`), so the two agree on DST-change days too, where it can differ
    /// by an hour from the wall-clock `dayStartHour`:00.
    static func startInstant(of localDate: String, dayStartHour: Int, timeZone: TimeZone) -> Date? {
        guard let comps = components(localDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: comps)?.addingTimeInterval(Double(dayStartHour) * 3600)
    }

    static func format(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func components(_ localDate: String) -> DateComponents? {
        let parts = localDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, localDate.count == 10 else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }
}
