import Combine
import Charts
import GRDB
import GRDBQuery
import Metrics
import SwiftUI

/// One calendar year of reading, for the Year in reading screen.
struct YearSnapshot: Equatable {
    var year = 0
    /// Current year back to the earliest session year, newest first.
    var years: [Int] = []
    var days: [String: Double] = [:]
    var monthMinutes: [Double] = Array(repeating: 0, count: 12)
    var finishedByMonth: [StatsSnapshot.MonthCount] = []
    var heatmap: [StatsSnapshot.HeatCell] = []
}

struct YearStatsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: YearSnapshot { YearSnapshot() }

    /// nil means the year of the current reading day (which honors the day-start hour).
    var year: Int?

    func fetch(_ db: Database) throws -> YearSnapshot {
        var snapshot = YearSnapshot()
        let today = try MetricsQueries.today(db)
        let currentYear = Int(today.prefix(4)) ?? Calendar.current.component(.year, from: .now)
        let year = self.year ?? currentYear
        snapshot.year = year
        let earliest = try MetricsQueries.firstReadingYear(db) ?? currentYear
        snapshot.years = Array(stride(from: currentYear, through: min(earliest, currentYear), by: -1))
        for entry in try MetricsQueries.calendarDays(db, year: year) {
            snapshot.days[entry.localDate] = entry.minutes
        }
        let months = try MetricsQueries.minutesByMonth(db, year: year)
        for entry in months where (1 ... 12).contains(entry.month) {
            snapshot.monthMinutes[entry.month - 1] = entry.minutes
        }
        snapshot.finishedByMonth = try MetricsQueries.booksFinishedByMonth(db, year: year).map {
            StatsSnapshot.MonthCount(month: $0.month, count: $0.count)
        }
        snapshot.heatmap = try MetricsQueries.hourWeekdayProfile(
            db, from: String(format: "%04d-01-01", year), to: String(format: "%04d-12-31", year)
        ).map { StatsSnapshot.HeatCell(weekday: $0.weekday, hour: $0.hour, minutes: $0.minutes) }
        return snapshot
    }
}

/// Year in reading: calendar heatmap, hours per month, books finished, time of day.
struct YearStatsView: View {
    /// nil until the reader picks one: the current reading-day year.
    @State private var year: Int?

    var body: some View {
        // A child view, so its `@Query` is re-created with the chosen year (see StatsContent).
        YearStatsContent(year: $year)
            .navigationTitle("Year in reading")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct YearStatsContent: View {
    @Binding var year: Int?
    @Query<YearStatsRequest> private var stats: YearSnapshot

    init(year: Binding<Int?>) {
        _year = year
        _stats = Query(constant: YearStatsRequest(year: year.wrappedValue))
    }

    private var shownYear: Int { year ?? stats.year }
    private var years: [Int] { stats.years.isEmpty ? [shownYear] : stats.years }
    private var yearSelection: Binding<Int> {
        Binding(get: { shownYear }, set: { year = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if years.count > 1 {
                    Picker("Year", selection: yearSelection) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ChartCard(title: "Reading days") { CalendarHeatmap(year: shownYear, days: stats.days) }
                ChartCard(title: "Hours per month") { MonthHoursChart(minutes: stats.monthMinutes) }
                ChartCard(title: "Books finished in \(String(shownYear))") {
                    FinishedChart(months: stats.finishedByMonth)
                }
                ChartCard(title: "When you read") { HeatmapChart(cells: stats.heatmap) }
            }
            .padding()
        }
    }
}

private struct MonthHoursChart: View {
    let minutes: [Double]

    var body: some View {
        if minutes.allSatisfy({ $0 == 0 }) {
            EmptyChart(text: "No reading in this year yet.")
        } else {
            Chart(Array(minutes.enumerated()), id: \.offset) { month, value in
                BarMark(
                    x: .value("Month", Calendar.current.shortMonthSymbols[month]),
                    y: .value("Hours", value / 60)
                )
            }
            .chartXScale(domain: Calendar.current.shortMonthSymbols)
            .chartYAxisLabel("h")
        }
    }
}

/// GitHub-style grid: weeks as columns, weekdays as rows (Sunday on top), five color steps.
private struct CalendarHeatmap: View {
    struct Cell: Identifiable {
        var id: String
        var week: Int
        var row: Int
        var level: Int
    }

    let year: Int
    let days: [String: Double]

    private var cells: [Cell] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        guard let jan1 = StatsDates.date(String(format: "%04d-01-01", year)),
              let dayCount = calendar.range(of: .day, in: .year, for: jan1)?.count else { return [] }
        let offset = calendar.component(.weekday, from: jan1) - 1
        let maxMinutes = days.values.max() ?? 0
        return (0 ..< dayCount).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: jan1) ?? jan1
            let key = String(format: "%04d-%02d-%02d", year, calendar.component(.month, from: date),
                             calendar.component(.day, from: date))
            let minutes = days[key] ?? 0
            let level = minutes > 0 && maxMinutes > 0 ? min(5, 1 + Int(4 * minutes / maxMinutes)) : 0
            return Cell(id: key, week: (index + offset) / 7, row: 6 - (index + offset) % 7, level: level)
        }
    }

    var body: some View {
        if days.isEmpty {
            EmptyChart(text: "No reading in this year yet.")
        } else {
            Chart(cells) { cell in
                RectangleMark(
                    xStart: .value("Week", Double(cell.week) + 0.06), xEnd: .value("Week", Double(cell.week) + 0.94),
                    yStart: .value("Day", Double(cell.row) + 0.06), yEnd: .value("Day", Double(cell.row) + 0.94)
                )
                .foregroundStyle(Self.color(level: cell.level))
            }
            // A year can touch 54 week columns (a leap year starting on Saturday).
            .chartXScale(domain: 0 ... 54)
            .chartYScale(domain: 0 ... 7)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: Array(0 ... 7)) { value in
                    AxisValueLabel(centered: true) {
                        if let row = value.as(Int.self), row < 7 {
                            Text(Calendar.current.veryShortWeekdaySymbols[6 - row])
                        }
                    }
                }
            }
        }
    }

    private static func color(level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.2 + 0.8 * Double(level - 1) / 4)
    }
}
