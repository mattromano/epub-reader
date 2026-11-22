import GRDB
import GRDBQuery
import Importing
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Observes the library for `@Query`: sort order and title/author search are request parameters.
struct LibraryRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [BookRecord] { [] }

    var sort: LibrarySort
    var search: String

    func fetch(_ db: Database) throws -> [BookRecord] {
        try LibraryRequests.books(sort: sort, search: search).fetchAll(db)
    }
}

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @AppStorage("librarySort") private var sortRaw = LibrarySort.recent.rawValue

    @State private var importer = ImportCoordinator()
    @State private var isPickingFile = false
    @State private var openBook: BookRecord?
    @State private var search = ""

    private var sort: Binding<LibrarySort> {
        Binding(
            get: { LibrarySort(rawValue: sortRaw) ?? .recent },
            set: { sortRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            // The list is a child view so its `@Query` is re-created with the current
            // sort/search (GRDBQuery applies a new initial request whenever the view is re-initialized).
            LibraryList(
                sort: sort.wrappedValue,
                search: search.trimmingCharacters(in: .whitespacesAndNewlines),
                importer: importer,
                isPickingFile: $isPickingFile,
                openBook: $openBook
            )
            .navigationTitle("Library")
            .searchable(text: $search, prompt: "Title or author")
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Picker("Sort by", selection: sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Import EPUB", systemImage: "plus")
                    }
                    .disabled(importer.isImporting)
                }
            }
            .overlay {
                if importer.isImporting {
                    ProgressView("Importing…")
                        .padding()
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await importer.importBooks(from: urls, environment: environment) }
            case let .failure(error):
                importer.notice = .init(title: "Couldn't open Files", message: error.localizedDescription)
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await importer.importBooks(from: [url], environment: environment) }
        }
        .alert(
            importer.notice?.title ?? "",
            isPresented: Binding(
                get: { importer.notice != nil },
                set: { if !$0 { importer.notice = nil } }
            ),
            presenting: importer.notice
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .fullScreenCover(item: $openBook) { book in
            ReaderScreen(book: book, environment: environment)
        }
    }
}

private struct LibraryList: View {
    @Environment(AppEnvironment.self) private var environment
    @Query<LibraryRequest> private var books: [BookRecord]

    let search: String
    let importer: ImportCoordinator
    @Binding var isPickingFile: Bool
    @Binding var openBook: BookRecord?

    @State private var bookPendingRemoval: BookRecord?
    @State private var detailBook: BookRecord?

    init(
        sort: LibrarySort,
        search: String,
        importer: ImportCoordinator,
        isPickingFile: Binding<Bool>,
        openBook: Binding<BookRecord?>
    ) {
        // `constant`: the request is rebuilt from sort/search on every init. Plain
        // `Query(_:)` only honors its first request, so search and sort wouldn't apply.
        _books = Query(constant: LibraryRequest(sort: sort, search: search))
        self.search = search
        self.importer = importer
        _isPickingFile = isPickingFile
        _openBook = openBook
    }

    var body: some View {
        content
            .confirmationDialog(
                bookPendingRemoval.map { "Remove “\($0.title)” from your library?" } ?? "",
                isPresented: Binding(
                    get: { bookPendingRemoval != nil },
                    set: { if !$0 { bookPendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: bookPendingRemoval
            ) { book in
                Button("Remove", role: .destructive) { remove(book) }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $detailBook) { book in
                BookDetailSheet(bookID: book.id)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let error = $books.error {
            ContentUnavailableView {
                Label("Couldn't load your library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
        } else if books.isEmpty && !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if books.isEmpty {
            ContentUnavailableView {
                Label("No books yet", systemImage: "books.vertical")
            } description: {
                Text("Margins reads DRM-free EPUBs.")
            } actions: {
                Button("Import an EPUB from Files") {
                    isPickingFile = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(importer.isImporting)
            }
        } else {
            List(books) { book in
                Button {
                    openBook = book
                } label: {
                    BookRow(book: book, coverURL: book.coverRelpath.map(environment.resolve))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Details", systemImage: "info.circle") {
                        detailBook = book
                    }
                    Menu("Mark as") {
                        ForEach(BookStatus.allCases, id: \.self) { status in
                            Button {
                                setStatus(status, for: book)
                            } label: {
                                if book.bookStatus == status {
                                    Label(status.displayName, systemImage: "checkmark")
                                } else {
                                    Text(status.displayName)
                                }
                            }
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        bookPendingRemoval = book
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        bookPendingRemoval = book
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func setStatus(_ status: BookStatus, for book: BookRecord) {
        let database = environment.database
        Task {
            do {
                try await database.setStatus(bookID: book.id, status: status)
            } catch {
                importer.notice = .init(title: "Couldn't update status", message: error.localizedDescription)
            }
        }
    }

    private func remove(_ book: BookRecord) {
        let database = environment.database
        Task {
            do {
                try await database.softDeleteBook(id: book.id)
            } catch {
                importer.notice = .init(title: "Couldn't remove book", message: error.localizedDescription)
            }
        }
    }
}

private struct BookRow: View {
    let book: BookRecord
    let coverURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            CoverThumbnail(url: coverURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                if !book.authors.isEmpty {
                    Text(book.authors)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lastOpenedText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        var parts = [book.bookStatus.displayName]
        let percent = Int((book.lastTotalProgression * 100).rounded())
        if percent > 0 { parts.append("\(percent)%") }
        if let words = BookFormatting.wordCountText(for: book) { parts.append(words) }
        return parts.joined(separator: " · ")
    }

    private var lastOpenedText: String {
        guard let string = book.lastOpenedAt, let date = Timestamp.date(from: string) else {
            return "Not opened yet"
        }
        return "Opened \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct CoverThumbnail: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "book.closed")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 48, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
    }
}
