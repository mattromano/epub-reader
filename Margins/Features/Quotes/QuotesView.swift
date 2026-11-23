import GRDB
import GRDBQuery
import Persistence
import SwiftUI
import UIKit

/// Observes the Quotes list for `@Query`; the filter is the request.
struct QuotesRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [QuoteItem] { [] }
    var filter: QuoteFilter

    func fetch(_ db: Database) throws -> [QuoteItem] {
        try QuoteRequests.quotes(filter).fetchAll(db)
    }
}

/// Books with at least one highlight, for the book chip and the Markdown export.
struct HighlightedBooksRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [BookRecord] { [] }

    func fetch(_ db: Database) throws -> [BookRecord] {
        try QuoteRequests.booksWithHighlights().fetchAll(db)
    }
}

/// The Quotes tab (SPEC §3): every highlight, searchable (FTS) and filterable by book, color and
/// tag, flat by date or grouped by book. Tap opens the reader there; swipe shares or deletes.
struct QuotesView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage("quotesSort") private var sortRaw = QuoteSort.recent.rawValue
    @Query(HighlightedBooksRequest()) private var books: [BookRecord]
    @Query(AllTagsRequest()) private var tags: [TagRecord]

    @State private var search = ""
    @State private var bookID: String?
    @State private var colors: Set<HighlightColor> = []
    @State private var tagID: String?
    @State private var openBook: ReaderRequest?
    @State private var imageQuote: QuoteItem?
    @State private var errorMessage: String?

    private var filter: QuoteFilter {
        QuoteFilter(search: search, bookID: bookID, colors: colors, tagID: tagID,
                    sort: QuoteSort(rawValue: sortRaw) ?? .recent)
    }

    private var isFiltered: Bool { bookID != nil || !colors.isEmpty || tagID != nil }

    var body: some View {
        NavigationStack {
            // A child view, so its `@Query` is re-created whenever the filter changes.
            QuotesList(filter: filter, isFiltered: isFiltered, open: open, shareImage: { imageQuote = $0 },
                       delete: delete)
                .navigationTitle("Quotes")
                .searchable(text: $search, prompt: "Quotes, notes, books")
                .safeAreaInset(edge: .top, spacing: 0) { filterBar }
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) { sortMenu }
                    ToolbarItem(placement: .primaryAction) { exportMenu }
                }
        }
        .fullScreenCover(item: $openBook) { request in
            ReaderScreen(book: request.book, environment: environment,
                         initialLocatorJSON: request.initialLocatorJSON)
        }
        .sheet(item: $imageQuote) { quote in
            QuoteImageSheet(quote: quote)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: books) { _, books in
            // A filtered book that lost its last highlight would leave an empty, stuck list.
            if let bookID, !books.contains(where: { $0.id == bookID }) { self.bookID = nil }
        }
    }

    // MARK: Toolbar

    private var sortMenu: some View {
        Menu {
            Picker("Show", selection: $sortRaw) {
                Label("By Date", systemImage: "calendar").tag(QuoteSort.recent.rawValue)
                Label("By Book", systemImage: "book").tag(QuoteSort.book.rawValue)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var exportMenu: some View {
        Menu {
            ShareLink(item: HighlightsCSVFile(database: environment.database),
                      preview: SharePreview("Margins highlights.csv")) {
                Label("All Highlights (CSV)", systemImage: "tablecells")
            }
            if !books.isEmpty {
                let titles = Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
                ShareLink(items: books.map { BookMarkdownFile(database: environment.database, bookID: $0.id) }) { file in
                    SharePreview("\(titles[file.bookID] ?? "Book").md")
                } label: {
                    Label("Each Book (Markdown)", systemImage: "doc.richtext")
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
    }

    // MARK: Filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Book", selection: $bookID) {
                        Text("All Books").tag(String?.none)
                        ForEach(books) { book in
                            Text(book.title).tag(Optional(book.id))
                        }
                    }
                } label: {
                    FilterChip(title: books.first { $0.id == bookID }?.title ?? "Book", isActive: bookID != nil)
                }

                Menu {
                    ForEach(HighlightColor.allCases, id: \.self) { color in
                        Toggle(isOn: Binding(
                            get: { colors.contains(color) },
                            set: { on in if on { colors.insert(color) } else { colors.remove(color) } }
                        )) {
                            Label(color.displayName, systemImage: "circle.fill")
                        }
                    }
                } label: {
                    FilterChip(title: colorChipTitle, isActive: !colors.isEmpty)
                }
                .menuActionDismissBehavior(.disabled)

                if !tags.isEmpty {
                    Menu {
                        Picker("Tag", selection: $tagID) {
                            Text("All Tags").tag(String?.none)
                            ForEach(tags) { tag in
                                Text(tag.name ?? "").tag(Optional(tag.id))
                            }
                        }
                    } label: {
                        FilterChip(title: tags.first { $0.id == tagID }?.name ?? "Tag", isActive: tagID != nil)
                    }
                }

                if isFiltered {
                    Button("Clear") {
                        bookID = nil
                        colors = []
                        tagID = nil
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var colorChipTitle: String {
        switch colors.count {
        case 0: "Color"
        case 1: colors.first!.displayName
        default: "\(colors.count) Colors"
        }
    }

    // MARK: Actions

    private func open(_ quote: QuoteItem) {
        guard let bookID = quote.highlight.bookID else { return }
        Task {
            do {
                guard let book = try await environment.database.book(id: bookID), book.deletedAt == nil else {
                    errorMessage = "This book is no longer in your library."
                    return
                }
                openBook = ReaderRequest(book: book, initialLocatorJSON: quote.highlight.locatorJSON)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ quote: QuoteItem) {
        let database = environment.database
        Task {
            do {
                try await database.softDeleteHighlight(id: quote.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.bold())
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
        .frame(maxWidth: 220)
    }
}

private struct QuotesList: View {
    @Query<QuotesRequest> private var quotes: [QuoteItem]
    let filter: QuoteFilter
    let isFiltered: Bool
    let open: (QuoteItem) -> Void
    let shareImage: (QuoteItem) -> Void
    let delete: (QuoteItem) -> Void

    init(filter: QuoteFilter, isFiltered: Bool, open: @escaping (QuoteItem) -> Void,
         shareImage: @escaping (QuoteItem) -> Void, delete: @escaping (QuoteItem) -> Void) {
        // `constant`: plain `Query(_:)` only honors its first request (see LibraryList).
        _quotes = Query(constant: QuotesRequest(filter: filter))
        self.filter = filter
        self.isFiltered = isFiltered
        self.open = open
        self.shareImage = shareImage
        self.delete = delete
    }

    var body: some View {
        if let error = $quotes.error {
            ContentUnavailableView {
                Label("Couldn't load your quotes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
        } else if quotes.isEmpty {
            emptyState
        } else {
            List {
                switch filter.sort {
                case .recent:
                    ForEach(quotes) { row($0, showBook: true) }
                case .book:
                    ForEach(groupedByBook, id: \.bookID) { group in
                        Section(group.title) {
                            ForEach(group.quotes) { row($0, showBook: false) }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let search = filter.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if isFiltered {
            ContentUnavailableView("No matching quotes", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Try clearing a filter."))
        } else {
            ContentUnavailableView("No quotes yet", systemImage: "quote.opening",
                                   description: Text("Highlights you make while reading show up here."))
        }
    }

    /// Consecutive runs of the same book (the `.book` sort keeps a book's quotes together).
    private var groupedByBook: [(bookID: String, title: String, quotes: [QuoteItem])] {
        var groups: [(bookID: String, title: String, quotes: [QuoteItem])] = []
        for quote in quotes {
            let id = quote.highlight.bookID ?? ""
            if groups.last?.bookID == id {
                groups[groups.count - 1].quotes.append(quote)
            } else {
                groups.append((id, quote.bookTitle, [quote]))
            }
        }
        return groups
    }

    private func row(_ quote: QuoteItem, showBook: Bool) -> some View {
        Button {
            open(quote)
        } label: {
            QuoteCard(quote: quote, showBook: showBook)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(quote)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            ShareLink(item: QuoteCard.shareText(quote)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button("Open in Book", systemImage: "book") { open(quote) }
            Button("Copy Quote", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = quote.highlight.quoteExact
            }
            ShareLink(item: QuoteCard.shareText(quote)) {
                Label("Share Text", systemImage: "square.and.arrow.up")
            }
            Button("Share as Image", systemImage: "photo") { shareImage(quote) }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(quote) }
        }
    }
}

/// One quote: the color bar, quote, note, and book · chapter · date (SPEC §3).
struct QuoteCard: View {
    let quote: QuoteItem
    var showBook = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(quote.highlight.highlightColor.color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(quote.highlight.quoteExact)
                    .font(.body)
                    .italic(quote.highlight.highlightStyle == .underline)
                    .underline(quote.highlight.highlightStyle == .underline)
                    .lineLimit(8)
                if let note = quote.highlight.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if !quote.tags.isEmpty {
                    Text(quote.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if quote.isOrphaned {
                        Label("Unanchored", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        var parts: [String] = []
        if showBook { parts.append(quote.bookTitle) }
        if let chapter = quote.highlight.chapterTitle, !chapter.isEmpty { parts.append(chapter) }
        parts.append(BookFormatting.date(quote.highlight.createdAt))
        return parts.joined(separator: " · ")
    }

    /// “quote” — Title, Author
    static func shareText(_ quote: QuoteItem) -> String {
        var source = quote.bookTitle
        if !quote.bookAuthors.isEmpty { source += ", \(quote.bookAuthors)" }
        return "“\(quote.highlight.quoteExact)” — \(source)"
    }
}
