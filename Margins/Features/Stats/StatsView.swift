import Combine
import Charts
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

/// Everything the Stats tab shows, read in one transaction (SPEC §6.3, PLAN M5 session B).
struct StatsSnapshot: Equatable {
    struct WPMPoint: Equatable, Identifiable {
        var id: Int
        var date: Date
        var wpm: Double
        /// Median of this and the previous `StatsSnapshot.medianWindow - 1` sessions.
        var rollingMedian: Double
    }

    struct HeatCell: Equatable, Identifiable {
        var id: String { "\(weekday)-\(hour)" }
        /// 1 = Sunday … 7 = Saturday (Calendar's numbering).
        var weekday: Int
        var hour: Int
        var minutes: Double
    }

    struct MonthCount: Equatable, Identifiable {
        var id: Int { month }
        var month: Int
        var count: Int
    }

    static let medianWindow = 7

    var today = ""
    var year = 0
    var todayMinutes = 0.0
    var goalMinutes: Double?
    var goalHitRate: Double?
    var streak = StreakSummary(current: 0, longest: 0, currentIncludesToday: false)
    var pace = PaceComparison(pace14: nil, pace90: nil)
    var lifetime = LifetimeTotals(activeSeconds: 0, wordsRead: 0, sessions: 0, booksFinished: 0)
    /// Last 30 reading days, for the overview chart.
    var daily: [DailyReading] = []
    var sessionsThisWeek = 0
    var medianSessionMinutes: Double?
    var longestSession: PersonalRecord?
    var minutesThisYear = 0.0
    var booksInProgress = 0
}

/// The Stats overview (stats-tab design, layout C): today, lifetime totals, a 30-day chart and
/// the headline number for each drill-down card.
struct StatsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: StatsSnapshot { StatsSnapshot() }

    static let overviewDays = 30

    func fetch(_ db: Database) throws -> StatsSnapshot {
        var snapshot = StatsSnapshot()
        let today = try MetricsQueries.today(db)
        let from = ReadingDays.adding(-(Self.overviewDays - 1), to: today) ?? today
        snapshot.today = today
        snapshot.year = Int(today.prefix(4)) ?? Calendar.current.component(.year, from: .now)

        snapshot.todayMinutes = try MetricsQueries.daily(db, from: today, to: today).first?.activeMinutes ?? 0
        snapshot.goalMinutes = try GoalRequests.current(.dailyMinutes).fetchOne(db)?.target
        snapshot.goalHitRate = try MetricsQueries.goalHitRate(db, today: today)
        let minMinutes = try AppDatabase.streakMinMinutes(db)
        snapshot.streak = try MetricsQueries.streaks(db, today: today, minMinutes: minMinutes)
        snapshot.pace = try MetricsQueries.paceComparison(db, today: today)
        snapshot.lifetime = try MetricsQueries.lifetimeTotals(db)
        snapshot.daily = try MetricsQueries.minutesPerDay(db, from: from, to: today)

        let week = try MetricsQueries.sessionsThisWeek(db, today: today)
        snapshot.sessionsThisWeek = week.count
        snapshot.medianSessionMinutes = week.medianMinutes
        snapshot.longestSession = try MetricsQueries.personalRecords(db, today: today, minMinutes: minMinutes)
            .first { $0.kind == .longestSession }
        snapshot.minutesThisYear = try MetricsQueries.minutesByMonth(db, year: snapshot.year)
            .reduce(0) { $0 + $1.minutes }
        snapshot.booksInProgress = try MetricsQueries.bookSummaries(db)
            .filter { $0.status == BookStatus.reading.rawValue }.count
        return snapshot
    }
}

/// `local_date` strings ↔ `Date` at local midnight, for chart axes.
enum StatsDates {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func date(_ localDate: String) -> Date? { formatter.date(from: localDate) }

    /// "Nov 3", or "Nov 3, 2025" when it isn't this year.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// The stats requests work out "today" when they fetch, and a `ValueObservation` only fetches
/// again after a database write. So the screens are rebuilt (fresh fetch) when the app comes back
/// and the clock hour has moved on, or the calendar day changes; that covers any day-start hour.
enum StatsRefresh {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH"
        return formatter
    }()

    static func token(_ now: Date = .now) -> String { formatter.string(from: now) }
}

extension EnvironmentValues {
    @Entry var statsRefreshToken = ""
}

private struct ReadingDayRefresh: ViewModifier {
    @Environment(\.statsRefreshToken) private var token
    func body(content: Content) -> some View { content.id(token) }
}

extension View {
    /// Re-creates this view (and its `@Query`) when the stats refresh token changes.
    func refreshesWithReadingDay() -> some View { modifier(ReadingDayRefresh()) }
}

/// Where each overview card leads.
enum StatsDestination: Hashable, CaseIterable {
    case speed, sessions, personalBests, year, books
}

struct StatsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshToken = StatsRefresh.token()

    var body: some View {
        NavigationStack {
            StatsContent()
                .refreshesWithReadingDay()
                .navigationTitle("Stats")
                .navigationDestination(for: StatsDestination.self) { destination in
                    destinationView(destination)
                        .refreshesWithReadingDay()
                }
        }
        .environment(\.statsRefreshToken, refreshToken)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshToken = StatsRefresh.token() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            refreshToken = StatsRefresh.token()
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: StatsDestination) -> some View {
        switch destination {
        case .speed: SpeedStatsView()
        case .sessions: SessionsStatsView()
        case .personalBests: PersonalBestsView()
        case .year: YearStatsView()
        case .books: BooksStatsView()
        }
    }
}

private struct StatsContent: View {
    @Query(StatsRequest()) private var stats: StatsSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TodayCard(stats: stats)
                LifetimeStrip(lifetime: stats.lifetime)
                ChartCard(title: "Minutes per day") { MinutesChart(daily: stats.daily, goal: stats.goalMinutes) }
                VStack(spacing: 10) {
                    ForEach(StatsDestination.allCases, id: \.self) { destination in
                        NavigationLink(value: destination) {
                            StatsNavCard(destination: destination, stats: stats)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

/// Hours, words, "≈ novels" and books finished, all time.
private struct LifetimeStrip: View {
    let lifetime: LifetimeTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All time")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                metric(StatsFormat.hours(lifetime.activeSeconds), "read")
                Spacer()
                metric(StatsFormat.compactCount(lifetime.wordsRead), "words")
                Spacer()
                metric("≈ \(StatsFormat.novels(lifetime.novelEquivalent))", "novels")
                Spacer()
                metric("\(lifetime.booksFinished)", "finished")
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One drill-down row: icon, title, headline number, chevron.
private struct StatsNavCard: View {
    let destination: StatsDestination
    let stats: StatsSnapshot

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch destination {
        case .speed: "Speed"
        case .sessions: "Sessions"
        case .personalBests: "Personal bests"
        case .year: "Year in reading"
        case .books: "Books"
        }
    }

    private var symbol: String {
        switch destination {
        case .speed: "speedometer"
        case .sessions: "clock"
        case .personalBests: "trophy"
        case .year: "calendar"
        case .books: "books.vertical"
        }
    }

    private var headline: String {
        switch destination {
        case .speed:
            guard let pace = stats.pace.pace14 else { return "Pace appears after a few sessions" }
            let wpm = "\(Int(pace.rounded())) wpm"
            guard let delta = stats.pace.deltaPercent else { return wpm }
            return "\(wpm) · \(StatsFormat.delta(delta)) vs 90-day"
        case .sessions:
            let count = stats.sessionsThisWeek == 1 ? "1 session" : "\(stats.sessionsThisWeek) sessions"
            guard let median = stats.medianSessionMinutes else { return "\(count) this week" }
            return "\(count) this week · \(ReadingTimeFormat.minutes(median)) typical"
        case .personalBests:
            guard let longest = stats.longestSession else { return "Read a bit to set records" }
            return "Longest session \(ReadingTimeFormat.minutes(longest.value / 60))"
        case .year:
            return "\(StatsFormat.hours(stats.minutesThisYear * 60)) in \(String(stats.year))"
        case .books:
            return stats.booksInProgress == 1 ? "1 in progress" : "\(stats.booksInProgress) in progress"
        }
    }
}

/// Number formats for the Stats tab.
enum StatsFormat {
    /// "142 h", "45 min" under an hour.
    static func hours(_ seconds: Double) -> String {
        let minutes = seconds / 60
        return minutes < 60 ? ReadingTimeFormat.minutes(minutes) : "\(Int((minutes / 60).rounded())) h"
    }

    /// "980", "48K", "3.1M".
    static func compactCount(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.significantDigits(1 ... 2)))
    }

    /// "34", "0.4" under one.
    static func novels(_ value: Double) -> String {
        value < 1 ? value.formatted(.number.precision(.fractionLength(1))) : "\(Int(value.rounded()))"
    }

    /// "↑4%", "↓3%", "±0%".
    static func delta(_ percent: Double) -> String {
        let rounded = Int(percent.rounded())
        if rounded == 0 { return "±0%" }
        return rounded > 0 ? "↑\(rounded)%" : "↓\(-rounded)%"
    }
}

private struct TodayCard: View {
    let stats: StatsSnapshot

    private var progress: Double {
        guard let goal = stats.goalMinutes, goal > 0 else { return 0 }
        return min(stats.todayMinutes / goal, 1)
    }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.headline)
                    .monospacedDigit()
            }
            .frame(width: 88, height: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text("Today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(ReadingTimeFormat.minutes(stats.todayMinutes))
                    .font(.title2.bold())
                    .monospacedDigit()
                if let goal = stats.goalMinutes {
                    Text("of \(ReadingTimeFormat.minutes(goal)) goal")
                        .foregroundStyle(.secondary)
                }
                if let pace = stats.pace.pace14 {
                    Text(Self.paceLine(pace, delta: stats.pace.deltaPercent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Self.streakLine(stats.streak))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let rate = stats.goalHitRate {
                    Text("Goal met on \(Int((rate * 100).rounded()))% of days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private static func paceLine(_ pace: Double, delta: Double?) -> String {
        let wpm = "\(Int(pace.rounded())) wpm"
        guard let delta else { return wpm }
        return "\(wpm) · \(StatsFormat.delta(delta)) vs 90-day"
    }

    private static func streakLine(_ streak: StreakSummary) -> String {
        let days = streak.current == 1 ? "1-day streak" : "\(streak.current)-day streak"
        if streak.current > 0, !streak.currentIncludesToday { return "\(days) · read today to keep it" }
        return "\(days) · best \(streak.longest)"
    }
}
