import Charts
import Combine
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

/// Data for the Sessions detail screen (stats-tab design, "Sessions").
struct SessionsSnapshot: Equatable {
    struct Day: Equatable, Identifiable {
        var localDate: String
        var sessions: [SessionLogEntry]
        var id: String { localDate }
    }

    var histogram: [SessionLengthBucket] = []
    /// Newest day first.
    var days: [Day] = []
}

struct SessionsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: SessionsSnapshot { SessionsSnapshot() }

    func fetch(_ db: Database) throws -> SessionsSnapshot {
        var snapshot = SessionsSnapshot()
        let today = try MetricsQueries.today(db)
        snapshot.histogram = try MetricsQueries.sessionLengthHistogram(db, from: "0000-01-01", to: today)
        // The log is newest first, so same-day sessions are adjacent.
        for entry in try MetricsQueries.sessionLog(db) {
            if snapshot.days.last?.localDate == entry.localDate {
                snapshot.days[snapshot.days.count - 1].sessions.append(entry)
            } else {
                snapshot.days.append(.init(localDate: entry.localDate, sessions: [entry]))
            }
        }
        return snapshot
    }
}

struct SessionsStatsView: View {
    @Query(constant: SessionsRequest()) private var sessions: SessionsSnapshot

    var body: some View {
        List {
            Section {
                ChartCard(title: "Session length") { HistogramChart(buckets: sessions.histogram) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if sessions.days.isEmpty {
                Section {
                    Text("No sessions yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sessions.days) { day in
                Section(Self.header(day.localDate)) {
                    ForEach(day.sessions) { SessionRow(entry: $0) }
                }
            }
        }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func header(_ localDate: String) -> String {
        guard let date = StatsDates.date(localDate) else { return localDate }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct HistogramChart: View {
    let buckets: [SessionLengthBucket]

    private func label(_ index: Int) -> String {
        let lower = buckets[index].lowerMinutes
        if index == buckets.count - 1 { return "\(lower)+" }
        return "\(lower)–\(buckets[index + 1].lowerMinutes)"
    }

    var body: some View {
        if buckets.allSatisfy({ $0.count == 0 }) {
            EmptyChart(text: "No sessions yet.")
        } else {
            Chart {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    BarMark(x: .value("Minutes", label(index)), y: .value("Sessions", bucket.count))
                }
            }
            .chartXScale(domain: buckets.indices.map(label))
            .chartXAxisLabel("minutes")
        }
    }
}

private struct SessionRow: View {
    let entry: SessionLogEntry

    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private var startTime: String? {
        guard let date = Self.withFraction.date(from: entry.startedAt) ?? Self.plain.date(from: entry.startedAt)
        else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var detail: String {
        var parts: [String] = []
        if let startTime { parts.append(startTime) }
        parts.append(ReadingTimeFormat.minutes(entry.activeSeconds / 60))
        if let wpm = entry.wpm { parts.append("\(Int(wpm.rounded())) wpm") }
        if entry.readingMode == "paginated", entry.pageTurns > 0 {
            parts.append(entry.pageTurns == 1 ? "1 page" : "\(entry.pageTurns) pages")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.bookTitle.isEmpty ? "Unknown book" : entry.bookTitle)
                .lineLimit(1)
            Text(detail)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
