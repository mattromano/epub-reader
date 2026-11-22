import Foundation

/// UTC ISO-8601 timestamps with milliseconds, the only timestamp format stored in the DB.
public enum Timestamp {
    private static let secondsStyle = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let parseStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    /// UTC ISO-8601 with milliseconds, e.g. "2026-11-22T07:41:11.123Z".
    /// Rounds to the nearest millisecond. (ISO8601FormatStyle truncates, so a Double like
    /// ...11.12299999 would otherwise print as .122.)
    public static func string(from date: Date) -> String {
        let totalMillis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (seconds, millis) = totalMillis.quotientAndRemainder(dividingBy: 1000)
        let wholeSeconds = millis < 0 ? seconds - 1 : seconds
        let positiveMillis = millis < 0 ? millis + 1000 : millis
        let base = Date(timeIntervalSince1970: TimeInterval(wholeSeconds)).formatted(secondsStyle)
        // base is "yyyy-MM-dd'T'HH:mm:ss'Z'"; splice the milliseconds in before the Z.
        return "\(base.dropLast()).\(String(format: "%03lld", positiveMillis))Z"
    }

    public static func date(from string: String) -> Date? {
        try? parseStyle.parse(string)
    }
}
