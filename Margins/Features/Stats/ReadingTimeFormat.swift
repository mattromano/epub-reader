import Foundation
import Metrics

/// Shared minute formatting for the reader chrome, stats and detail sheets.
enum ReadingTimeFormat {
    /// "45 min", "1 h 5 m", "<1 min".
    static func minutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if minutes > 0, total == 0 { return "<1 min" }
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// "8 min left in chapter · 3 h 10 m in book", or whichever half is known.
    static func timeLeft(_ timeLeft: TimeLeft?) -> String? {
        guard let timeLeft else { return nil }
        var parts: [String] = []
        if let chapter = timeLeft.chapterMinutes { parts.append("\(minutes(chapter)) left in chapter") }
        if let book = timeLeft.bookMinutes {
            parts.append(parts.isEmpty ? "\(minutes(book)) left in book" : "\(minutes(book)) in book")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
