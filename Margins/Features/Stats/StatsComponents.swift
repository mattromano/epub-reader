import Charts
import Metrics
import SwiftUI

// Shared Stats building blocks (tiles, chart cards, charts), used by the overview and the
// detail screens.

struct StatTile: View {
    let title: String
    let value: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(caption ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
                .frame(height: 180)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MinutesChart: View {
    let daily: [DailyReading]
    let goal: Double?

    var body: some View {
        if daily.allSatisfy({ $0.activeMinutes == 0 }) {
            EmptyChart(text: "No reading in this range yet.")
        } else {
            Chart {
                ForEach(daily, id: \.localDate) { day in
                    if let date = StatsDates.date(day.localDate) {
                        // RectangleMark, not BarMark: iOS 27 BarMark time ranges can fail to render.
                        RectangleMark(
                            xStart: .value("Day", date),
                            xEnd: .value("Day", date.addingTimeInterval(86_400 * 0.8)),
                            yStart: .value("Minutes", 0),
                            yEnd: .value("Minutes", day.activeMinutes)
                        )
                        .foregroundStyle(day.goalMet ? Color.accentColor : Color.accentColor.opacity(0.45))
                    }
                }
                if let goal {
                    RuleMark(y: .value("Goal", goal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                }
            }
            .chartYAxisLabel("min")
        }
    }
}

struct WPMChart: View {
    let points: [StatsSnapshot.WPMPoint]

    var body: some View {
        if points.isEmpty {
            EmptyChart(text: "Reading speed appears after a few sessions.")
        } else {
            Chart {
                ForEach(points) { point in
                    PointMark(x: .value("Date", point.date), y: .value("WPM", point.wpm))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .symbolSize(18)
                }
                ForEach(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Median", point.rollingMedian))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYAxisLabel("WPM")
        }
    }
}

struct HeatmapChart: View {
    let cells: [StatsSnapshot.HeatCell]

    var body: some View {
        if cells.isEmpty {
            EmptyChart(text: "No reading in this range yet.")
        } else {
            Chart(cells) { cell in
                RectangleMark(
                    xStart: .value("Hour", cell.hour), xEnd: .value("Hour", cell.hour + 1),
                    // Sunday on top: row 7 - weekday.
                    yStart: .value("Weekday", 7 - cell.weekday), yEnd: .value("Weekday", 8 - cell.weekday)
                )
                .foregroundStyle(by: .value("Minutes", cell.minutes))
            }
            .chartForegroundStyleScale(range: Gradient(colors: [Color.accentColor.opacity(0.15), Color.accentColor]))
            .chartXScale(domain: 0 ... 24)
            .chartYScale(domain: 0 ... 7)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hour = value.as(Int.self) { Text("\(hour)") } }
                }
            }
            .chartYAxis {
                // Ticks at row edges; a centered label sits between a tick and the next one,
                // so the extra tick at 7 is what gives the top row its label.
                AxisMarks(values: Array(0 ... 7)) { value in
                    AxisValueLabel(centered: true) {
                        if let row = value.as(Int.self), row < 7 {
                            Text(Calendar.current.veryShortWeekdaySymbols[6 - row])
                        }
                    }
                }
            }
            .chartLegend(.hidden)
        }
    }
}

struct FinishedChart: View {
    let months: [StatsSnapshot.MonthCount]

    var body: some View {
        if months.allSatisfy({ $0.count == 0 }) {
            EmptyChart(text: "Mark a book finished to see it here.")
        } else {
            Chart(months) { month in
                BarMark(
                    x: .value("Month", Calendar.current.shortMonthSymbols[month.month - 1]),
                    y: .value("Books", month.count)
                )
            }
            .chartXScale(domain: Calendar.current.shortMonthSymbols)
        }
    }
}

struct EmptyChart: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
