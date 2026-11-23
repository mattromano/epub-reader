import Foundation

/// One stat the reader can show in its tap panel or always-on line (reader-stats design).
/// Raw values are stored in `app_setting`; never rename them.
public enum ReaderStat: String, CaseIterable, Codable, Sendable, Identifiable {
    case chapterTimeLeft = "chapter_time_left"
    case bookTimeLeft = "book_time_left"
    case bookPercent = "book_percent"
    case sessionTime = "session_time"
    case sessionWPM = "session_wpm"
    case wpmVsUsual = "wpm_vs_usual"
    case sessionWords = "session_words"
    case sessionPages = "session_pages"
    case pagesPerMinute = "pages_per_minute"
    case todayVsGoal = "today_vs_goal"

    public var id: String { rawValue }

    /// Label in Settings.
    public var title: String {
        switch self {
        case .chapterTimeLeft: "Time left in chapter"
        case .bookTimeLeft: "Time left in book"
        case .bookPercent: "Percent of book"
        case .sessionTime: "Session time"
        case .sessionWPM: "Words per minute"
        case .wpmVsUsual: "Speed vs usual"
        case .sessionWords: "Words this session"
        case .sessionPages: "Pages this session"
        case .pagesPerMinute: "Pages per minute"
        case .todayVsGoal: "Today vs goal"
        }
    }
}

/// Which stats the reader shows, stored as two `app_setting` rows.
public struct ReaderStatsSettings: Equatable, Sendable {
    public static let panelKey = "reader_stats_panel"
    public static let lineKey = "reader_stats_line"
    public static let maxLineStats = 3

    /// Tap panel, in display order.
    public var panel: [ReaderStat]
    /// Always-on line under the page.
    public var lineEnabled: Bool
    /// Always-on line stats, in order; at most `maxLineStats`.
    public var line: [ReaderStat]

    public init(panel: [ReaderStat], lineEnabled: Bool, line: [ReaderStat]) {
        self.panel = panel
        self.lineEnabled = lineEnabled
        self.line = line
    }

    public static let `default` = ReaderStatsSettings(
        panel: [.chapterTimeLeft, .bookTimeLeft, .sessionTime, .sessionWPM, .wpmVsUsual,
                .sessionPages, .pagesPerMinute, .todayVsGoal],
        lineEnabled: true,
        line: [.chapterTimeLeft, .sessionWPM])

    /// Decodes the stored rows. A missing or unreadable row means that part's default; unknown
    /// ids are dropped; duplicates keep the first; `line` is cut to `maxLineStats`.
    public static func decode(panelJSON: String?, lineJSON: String?) -> ReaderStatsSettings {
        let decoder = JSONDecoder()
        var result = ReaderStatsSettings.default
        if let ids = panelJSON.flatMap({ $0.data(using: .utf8) })
            .flatMap({ try? decoder.decode([String].self, from: $0) }) {
            result.panel = stats(from: ids)
        }
        if let stored = lineJSON.flatMap({ $0.data(using: .utf8) })
            .flatMap({ try? decoder.decode(StoredLine.self, from: $0) }) {
            result.lineEnabled = stored.enabled
            result.line = Array(stats(from: stored.stats).prefix(maxLineStats))
        }
        return result
    }

    /// `["chapter_time_left", …]`
    public func encodedPanelJSON() -> String {
        Self.encode(panel.map(\.rawValue))
    }

    /// `{"enabled":true,"stats":["chapter_time_left","session_wpm"]}`
    public func encodedLineJSON() -> String {
        Self.encode(StoredLine(enabled: lineEnabled, stats: line.map(\.rawValue)))
    }

    private struct StoredLine: Codable {
        var enabled: Bool
        var stats: [String]
    }

    /// Known ids in order, first occurrence only.
    private static func stats(from ids: [String]) -> [ReaderStat] {
        var seen = Set<ReaderStat>()
        return ids.compactMap(ReaderStat.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
