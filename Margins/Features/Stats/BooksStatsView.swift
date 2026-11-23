import Combine
import GRDB
import GRDBQuery
import Metrics
import SwiftUI

struct BookSummariesRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [BookSummary] { [] }

    func fetch(_ db: Database) throws -> [BookSummary] {
        try MetricsQueries.bookSummaries(db)
    }
}

/// Every book with reading, most recently read first; each row opens that book's stats.
struct BooksStatsView: View {
    @Query(BookSummariesRequest()) private var books: [BookSummary]

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView("No books read yet", systemImage: "books.vertical",
                                       description: Text("Books appear here after you read for a while."))
            } else {
                List(books) { book in
                    NavigationLink {
                        BookStatsView(bookID: book.bookID)
                            .refreshesWithReadingDay()
                    } label: {
                        BookSummaryRow(book: book)
                    }
                }
            }
        }
        .navigationTitle("Books")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BookSummaryRow: View {
    let book: BookSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.title)
                .font(.headline)
            if !book.authors.isEmpty {
                Text(book.authors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let pct = book.pctComplete {
                ProgressView(value: min(max(pct, 0), 1))
            }
            HStack {
                Text(ReadingTimeFormat.minutes(book.activeMinutes))
                Text("·")
                Text(book.wpm.map { "\(Int($0.rounded())) WPM" } ?? "— WPM")
                if let pct = book.pctComplete {
                    Spacer()
                    Text(pct.formatted(.percent.precision(.fractionLength(0))))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
