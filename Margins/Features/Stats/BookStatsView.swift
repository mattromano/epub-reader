import Combine
import Charts
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

struct BookStatsSnapshot: Equatable {
    var title = ""
    var authors = ""
    var stats: BookStats?
    var highlightDensity: Double?
    var projectedFinish: String?
    var chapters: [ChapterPace] = []
    var sessions: [SessionLogEntry] = []
}

struct BookStatsPageRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: BookStatsSnapshot { BookStatsSnapshot() }

    var bookID: String

    func fetch(_ db: Database) throws -> BookStatsSnapshot {
        var snapshot = BookStatsSnapshot()
        if let book = try BookRecord
            .filter(BookRecord.Columns.id == bookID)
            .filter(BookRecord.Columns.deletedAt == nil)
            .fetchOne(db) {
            snapshot.title = book.title
            snapshot.authors = book.authors
        }
        snapshot.stats = try MetricsQueries.bookStats(db, bookID: bookID)
        snapshot.highlightDensity = try MetricsQueries.highlightDensity(db, bookID: bookID)
        snapshot.projectedFinish = try MetricsQueries.projectedFinish(
            db, bookID: bookID, today: try MetricsQueries.today(db))
        snapshot.chapters = try MetricsQueries.chapterPace(db, bookID: bookID)
        snapshot.sessions = try MetricsQueries.sessionLog(db, bookID: bookID)
        return snapshot
    }
}

/// Stats for one book: totals, projected finish, per-chapter pace and its sessions.
struct BookStatsView: View {
    @Query<BookStatsPageRequest> private var page: BookStatsSnapshot

    init(bookID: String) {
        // `constant`: plain `Query(_:)` only honors its first request (see LibraryList).
        _page = Query(constant: BookStatsPageRequest(bookID: bookID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let stats = page.stats, stats.sessions > 0 {
                    tiles(stats)
                    if let finish = Self.finishText(page.projectedFinish) {
                        Label(finish, systemImage: "flag.checkered")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No reading on this book yet.")
                        .foregroundStyle(.secondary)
                }
                ChartCard(title: "Minutes per chapter") { ChapterPaceChart(chapters: page.chapters) }
                if !page.chapters.isEmpty { chapterList }
                if !page.sessions.isEmpty { sessionList }
            }
            .padding()
        }
        .navigationTitle(page.title.isEmpty ? "Book stats" : page.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(page.title)
                .font(.title2.bold())
            if !page.authors.isEmpty {
                Text(page.authors)
                    .foregroundStyle(.secondary)
            }
            if let pct = page.stats?.pctComplete {
                ProgressView(value: min(max(pct, 0), 1)) {
                    Text("\(pct.formatted(.percent.precision(.fractionLength(0)))) complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tiles(_ stats: BookStats) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(title: "Total time", value: ReadingTimeFormat.minutes(stats.totalActiveMinutes), caption: nil)
                StatTile(title: "Average pace", value: stats.avgWPM.map { "\(Int($0.rounded())) WPM" } ?? "—",
                         caption: nil)
            }
            HStack(spacing: 12) {
                StatTile(title: "Sessions", value: stats.sessions.formatted(), caption: nil)
                StatTile(title: "Highlights",
                         value: page.highlightDensity
                             .map { $0.formatted(.number.precision(.fractionLength(0 ... 1))) } ?? "—",
                         caption: "Per 10k words")
            }
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.headline)
            ForEach(page.chapters) { chapter in
                HStack {
                    Text(chapter.title ?? "Chapter \(chapter.spineIndex + 1)")
                        .lineLimit(1)
                    Spacer()
                    Text("\(ReadingTimeFormat.minutes(chapter.minutes)) · \(chapter.wpm.map { "\(Int($0.rounded())) WPM" } ?? "— WPM")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.headline)
            ForEach(page.sessions) { session in
                HStack {
                    Text(BookFormatting.dateTime(session.startedAt))
                    Spacer()
                    Text(Self.sessionDetail(session))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    private static func sessionDetail(_ session: SessionLogEntry) -> String {
        var parts = [ReadingTimeFormat.minutes(session.activeSeconds / 60)]
        if let wpm = session.wpm { parts.append("\(Int(wpm.rounded())) WPM") }
        return parts.joined(separator: " · ")
    }

    /// "Finish by Dec 14" from a `local_date`, or nil.
    private static func finishText(_ localDate: String?) -> String? {
        guard let localDate, let date = StatsDates.date(localDate) else { return nil }
        return "Finish by \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

private struct ChapterPaceChart: View {
    let chapters: [ChapterPace]

    var body: some View {
        if chapters.isEmpty {
            EmptyChart(text: "Chapter pace appears after you read this book.")
        } else {
            Chart(chapters) { chapter in
                // RectangleMark, not BarMark: iOS 27 BarMark can fail to render.
                RectangleMark(
                    xStart: .value("Chapter", Double(chapter.spineIndex) + 0.1),
                    xEnd: .value("Chapter", Double(chapter.spineIndex) + 0.9),
                    yStart: .value("Minutes", 0), yEnd: .value("Minutes", chapter.minutes)
                )
            }
            .chartXAxisLabel("Chapter (spine order)")
            .chartYAxisLabel("min")
        }
    }
}
