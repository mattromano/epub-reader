import Charts
import Combine
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

/// Data for the Speed detail screen (stats-tab design, "Speed").
struct SpeedSnapshot: Equatable {
    var wpm: [StatsSnapshot.WPMPoint] = []
    var pagesPerMinute: [PagesPerMinutePoint] = []
    var byBook: [SpeedGroup] = []
    var byTimeBand: [SpeedGroup] = []
    var byFontSize: [SpeedGroup] = []
}

struct SpeedRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: SpeedSnapshot { SpeedSnapshot() }

    var rangeDays: Int

    func fetch(_ db: Database) throws -> SpeedSnapshot {
        var snapshot = SpeedSnapshot()
        let today = try MetricsQueries.today(db)
        let from = ReadingDays.adding(-(rangeDays - 1), to: today) ?? today

        let sessions = try MetricsQueries.sessionWPM(db, from: from, to: today)
        snapshot.wpm = sessions.enumerated().compactMap { offset, point in
            guard let date = StatsDates.date(point.localDate) else { return nil }
            let window = sessions[max(0, offset - StatsSnapshot.medianWindow + 1)...offset].map(\.wpm).sorted()
            let mid = window.count / 2
            let median = window.count.isMultiple(of: 2) ? (window[mid - 1] + window[mid]) / 2 : window[mid]
            return StatsSnapshot.WPMPoint(id: offset, date: date, wpm: point.wpm, rollingMedian: median)
        }
        snapshot.pagesPerMinute = try MetricsQueries.pagesPerMinuteTrend(db, from: from, to: today)
        snapshot.byBook = try MetricsQueries.wpmByBook(db, from: from, to: today)
        snapshot.byTimeBand = try MetricsQueries.wpmByTimeBand(db, from: from, to: today)
        snapshot.byFontSize = try MetricsQueries.wpmByFontSize(db, from: from, to: today)
        return snapshot
    }
}

struct SpeedStatsView: View {
    @AppStorage("statsRangeDays") private var rangeDays = 30

    var body: some View {
        // A child view, so its `@Query` is re-created with the current range.
        SpeedStatsContent(rangeDays: $rangeDays)
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpeedStatsContent: View {
    @Binding var rangeDays: Int
    @Query<SpeedRequest> private var speed: SpeedSnapshot

    init(rangeDays: Binding<Int>) {
        _rangeDays = rangeDays
        _speed = Query(constant: SpeedRequest(rangeDays: rangeDays.wrappedValue))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $rangeDays) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.segmented)

                ChartCard(title: "Reading speed") { WPMChart(points: speed.wpm) }
                ChartCard(title: "Pages per minute") { PagesPerMinuteChart(points: speed.pagesPerMinute) }
                GroupCard(title: "By book", groups: speed.byBook)
                GroupCard(title: "By time of day", groups: speed.byTimeBand)
                GroupCard(title: "By font size", groups: speed.byFontSize)
            }
            .padding()
        }
    }
}

private struct PagesPerMinuteChart: View {
    let points: [PagesPerMinutePoint]

    var body: some View {
        if points.isEmpty {
            EmptyChart(text: "Not enough reading yet.")
        } else {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    if let date = StatsDates.date(point.localDate) {
                        LineMark(x: .value("Date", date), y: .value("Pages/min", point.pagesPerMinute))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", date), y: .value("Pages/min", point.pagesPerMinute))
                            .symbolSize(18)
                    }
                }
            }
            .chartYAxisLabel("pages/min")
        }
    }
}

/// A bar list: label, WPM and minutes per row, bar length relative to the fastest group.
private struct GroupCard: View {
    let title: String
    let groups: [SpeedGroup]

    private var maxWPM: Double { max(groups.map(\.wpm).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            if groups.isEmpty {
                Text("Not enough reading yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.label)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int(group.wpm.rounded())) wpm · \(ReadingTimeFormat.minutes(group.minutes))")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(4, proxy.size.width * group.wpm / maxWPM))
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}
