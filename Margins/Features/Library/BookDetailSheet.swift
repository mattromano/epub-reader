import Combine
import GRDB
import GRDBQuery
import Importing
import Metrics
import Persistence
import SwiftUI

/// Observes one live book row for `@Query` (nil once it's gone or soft-deleted).
struct BookDetailRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: BookRecord? { nil }

    var bookID: String

    func fetch(_ db: Database) throws -> BookRecord? {
        try BookRecord
            .filter(BookRecord.Columns.id == bookID)
            .filter(BookRecord.Columns.deletedAt == nil)
            .fetchOne(db)
    }
}

/// Observes a book's non-deleted sessions, newest first, for `@Query`.
struct BookSessionsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [SessionRecord] { [] }

    var bookID: String

    func fetch(_ db: Database) throws -> [SessionRecord] {
        try SessionRequests.sessions(bookID: bookID).fetchAll(db)
    }
}

/// Observes a book's non-deleted highlights in reading order, for `@Query`.
struct BookHighlightsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [HighlightRecord] { [] }

    var bookID: String

    func fetch(_ db: Database) throws -> [HighlightRecord] {
        try HighlightRequests.highlights(bookID: bookID).fetchAll(db)
    }
}

/// Observes a book's `agg_book_stats` row (PLAN M5), for `@Query`.
struct BookStatsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: BookStats? { nil }

    var bookID: String

    func fetch(_ db: Database) throws -> BookStats? {
        try MetricsQueries.bookStats(db, bookID: bookID)
    }
}

/// Book metadata, highlights (PLAN M3) and reading sessions (PLAN M2). Swipe soft-deletes a
/// highlight or a session; tapping a highlight opens the reader there.
struct BookDetailSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query<BookDetailRequest> private var book: BookRecord?
    @Query<BookSessionsRequest> private var sessions: [SessionRecord]
    @Query<BookHighlightsRequest> private var highlights: [HighlightRecord]
    @Query<BookStatsRequest> private var stats: BookStats?
    private let openHighlight: (HighlightRecord) -> Void

    @State private var deleteError: String?

    init(bookID: String, openHighlight: @escaping (HighlightRecord) -> Void = { _ in }) {
        // `constant`: plain `Query(_:)` only honors its first request (see LibraryList).
        _book = Query(constant: BookDetailRequest(bookID: bookID))
        _sessions = Query(constant: BookSessionsRequest(bookID: bookID))
        _highlights = Query(constant: BookHighlightsRequest(bookID: bookID))
        _stats = Query(constant: BookStatsRequest(bookID: bookID))
        self.openHighlight = openHighlight
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    if let book, !highlights.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            ShareLink(item: BookMarkdownFile(database: environment.database, bookID: book.id),
                                      preview: SharePreview("\(book.title).md")) {
                                Label("Export Highlights", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
                .alert(
                    "Couldn't delete",
                    isPresented: Binding(
                        get: { deleteError != nil },
                        set: { if !$0 { deleteError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(deleteError ?? "")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let book {
            List {
                metadataSection(book)
                statsSection
                highlightsSection
                sessionsSection
            }
        } else {
            ContentUnavailableView("This book is no longer in your library", systemImage: "book.closed")
        }
    }

    private func metadataSection(_ book: BookRecord) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                if !book.authors.isEmpty {
                    Text(book.authors)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Status", value: book.bookStatus.displayName)
            LabeledContent("Words", value: BookFormatting.wordCountValue(for: book))
            LabeledContent("Chapters", value: book.chapterCount.map { $0.formatted() } ?? "—")
            LabeledContent("Imported", value: BookFormatting.date(book.createdAt))
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        if let stats, stats.sessions > 0 {
            Section("Reading") {
                NavigationLink("Reading stats") { BookStatsView(bookID: stats.bookID).refreshesWithReadingDay() }
                LabeledContent("Time read", value: ReadingTimeFormat.minutes(stats.totalActiveMinutes))
                LabeledContent("Words read", value: stats.totalWordsRead.formatted())
                LabeledContent("Sessions", value: stats.sessions.formatted())
                if let wpm = stats.avgWPM {
                    LabeledContent("Pace", value: "\(Int(wpm.rounded())) WPM")
                }
                if let median = stats.medianSessionMinutes {
                    LabeledContent("Typical session", value: ReadingTimeFormat.minutes(median))
                }
                if let pct = stats.pctComplete {
                    LabeledContent("Complete", value: pct.formatted(.percent.precision(.fractionLength(0))))
                }
                if stats.highlights > 0, stats.totalWordsRead > 0 {
                    LabeledContent("Highlights per 10k words",
                                   value: (Double(stats.highlights) * 10_000 / Double(stats.totalWordsRead))
                                       .formatted(.number.precision(.fractionLength(0 ... 1))))
                }
            }
        }
    }

    @ViewBuilder
    private var highlightsSection: some View {
        Section("Highlights") {
            if highlights.isEmpty {
                Text("No highlights yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(highlights) { highlight in
                    Button {
                        openHighlight(highlight)
                    } label: {
                        HighlightRow(highlight: highlight)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteHighlights)
            }
        }
    }

    private func deleteHighlights(at offsets: IndexSet) {
        let ids = offsets.map { highlights[$0].id }
        let database = environment.database
        Task {
            do {
                for id in ids {
                    try await database.softDeleteHighlight(id: id)
                }
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var sessionsSection: some View {
        Section("Sessions") {
            if let error = $sessions.error {
                Text("Sessions couldn't be loaded. \(error.localizedDescription)")
                    .foregroundStyle(.secondary)
            } else if sessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "clock",
                    description: Text("Reading sessions appear here after you read for a while.")
                )
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                }
                .onDelete(perform: deleteSessions)
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        let ids = offsets.map { sessions[$0].id }
        let database = environment.database
        Task {
            do {
                for id in ids {
                    try await database.softDeleteSession(id: id)
                }
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(BookFormatting.dateTime(session.startedAt))
                .font(.subheadline)
            Text(statsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var statsText: String {
        var parts = [minutesText, "\(session.wordsRead.formatted()) words"]
        if session.isPaceEligible, let wpm = session.wordsPerMinute {
            parts.append("\(Int(wpm.rounded()).formatted()) WPM")
        }
        return parts.joined(separator: " · ")
    }

    /// Whole minutes from 10 up, one decimal below.
    private var minutesText: String {
        let minutes = session.activeSeconds / 60
        let rounded = minutes >= 10 ? minutes.rounded() : (minutes * 10).rounded() / 10
        return "\(rounded.formatted(.number.precision(.fractionLength(0 ... 1)))) min"
    }
}

/// Shared captions for the library row and the detail sheet.
enum BookFormatting {
    /// True while a reflowable book's index is missing or out of date.
    static func isIndexing(_ book: BookRecord) -> Bool {
        book.layout != "fixed" && book.indexVersion < WordIndexer.version
    }

    /// "Indexing…", "52,310 words", or nil (fixed layout, or skipped).
    static func wordCountText(for book: BookRecord) -> String? {
        if isIndexing(book) { return "Indexing…" }
        guard let count = book.wordCount else { return nil }
        return count == 1 ? "1 word" : "\(count.formatted()) words"
    }

    /// Value for the detail sheet's "Words" row.
    static func wordCountValue(for book: BookRecord) -> String {
        if isIndexing(book) { return "Indexing…" }
        return book.wordCount.map { $0.formatted() } ?? "—"
    }

    /// Stored UTC timestamp → local date.
    static func date(_ timestamp: String?) -> String {
        guard let timestamp, let date = Timestamp.date(from: timestamp) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Stored UTC timestamp → local date and time.
    static func dateTime(_ timestamp: String?) -> String {
        guard let timestamp, let date = Timestamp.date(from: timestamp) else { return "Unknown date" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
