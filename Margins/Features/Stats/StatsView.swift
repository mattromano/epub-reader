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
    var streak = StreakSummary(current: 0, longest: 0, currentIncludesToday: false)
    var rollingPace: Double?
    var goalHitRate: Double?
    var daily: [DailyReading] = []
    var wpm: [WPMPoint] = []
    var heatmap: [HeatCell] = []
    var finishedByMonth: [MonthCount] = []
    var finishedThisYear = 0
}

struct StatsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: StatsSnapshot { StatsSnapshot() }

    var rangeDays: Int

    func fetch(_ db: Database) throws -> StatsSnapshot {
        var snapshot = StatsSnapshot()
        let today = try MetricsQueries.today(db)
        let from = ReadingDays.adding(-(rangeDays - 1), to: today) ?? today
        snapshot.today = today
        snapshot.year = Int(today.prefix(4)) ?? Calendar.current.component(.year, from: .now)

        let todayRow = try MetricsQueries.daily(db, from: today, to: today).first
        snapshot.todayMinutes = todayRow?.activeMinutes ?? 0
        snapshot.goalMinutes = try GoalRequests.current(.dailyMinutes).fetchOne(db)?.target
        snapshot.streak = try MetricsQueries.streaks(
            db, today: today, minMinutes: try AppDatabase.streakMinMinutes(db))
        snapshot.rollingPace = try MetricsQueries.rollingPace(db, today: today)
        snapshot.goalHitRate = try MetricsQueries.goalHitRate(db, today: today)
        snapshot.daily = try MetricsQueries.minutesPerDay(db, from: from, to: today)

        let sessions = try MetricsQueries.sessionWPM(db, from: from, to: today)
        snapshot.wpm = sessions.enumerated().compactMap { offset, point in
            guard let date = StatsDates.date(point.localDate) else { return nil }
            let window = sessions[max(0, offset - StatsSnapshot.medianWindow + 1)...offset].map(\.wpm).sorted()
            let mid = window.count / 2
            let median = window.count.isMultiple(of: 2) ? (window[mid - 1] + window[mid]) / 2 : window[mid]
            return StatsSnapshot.WPMPoint(id: offset, date: date, wpm: point.wpm, rollingMedian: median)
        }
        snapshot.heatmap = try MetricsQueries.hourWeekdayProfile(db, from: from, to: today).map {
            StatsSnapshot.HeatCell(weekday: $0.weekday, hour: $0.hour, minutes: $0.minutes)
        }
        snapshot.finishedByMonth = try MetricsQueries.booksFinishedByMonth(db, year: snapshot.year).map {
            StatsSnapshot.MonthCount(month: $0.month, count: $0.count)
        }
        snapshot.finishedThisYear = try MetricsQueries.booksFinished(db, year: snapshot.year)
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
}

struct StatsView: View {
    @AppStorage("statsRangeDays") private var rangeDays = 30

    var body: some View {
        NavigationStack {
            // A child view, so its `@Query` is re-created with the current range
            // (`Query(_:)` only honors its first request; see LibraryList).
            StatsContent(rangeDays: $rangeDays)
                .navigationTitle("Stats")
        }
    }
}

private struct StatsContent: View {
    @Binding var rangeDays: Int
    @Query<StatsRequest> private var stats: StatsSnapshot

    init(rangeDays: Binding<Int>) {
        _rangeDays = rangeDays
        _stats = Query(constant: StatsRequest(rangeDays: rangeDays.wrappedValue))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TodayCard(stats: stats)
                HStack(spacing: 12) {
                    StatTile(title: "Current streak", value: Self.days(stats.streak.current),
                             caption: stats.streak.current > 0 && !stats.streak.currentIncludesToday
                                 ? "Read today to keep it" : nil)
                    StatTile(title: "Longest streak", value: Self.days(stats.streak.longest), caption: nil)
                }
                HStack(spacing: 12) {
                    StatTile(title: "Pace", value: stats.rollingPace.map { "\(Int($0.rounded())) WPM" } ?? "—",
                             caption: "Last 14 days")
                    StatTile(title: "Books finished", value: "\(stats.finishedThisYear)",
                             caption: "In \(String(stats.year))")
                }

                Picker("Range", selection: $rangeDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)

                ChartCard(title: "Minutes per day") { MinutesChart(daily: stats.daily, goal: stats.goalMinutes) }
                ChartCard(title: "Reading speed") { WPMChart(points: stats.wpm) }
                ChartCard(title: "When you read") { HeatmapChart(cells: stats.heatmap) }
                ChartCard(title: "Books finished in \(String(stats.year))") {
                    FinishedChart(months: stats.finishedByMonth)
                }
            }
            .padding()
        }
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
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
}
