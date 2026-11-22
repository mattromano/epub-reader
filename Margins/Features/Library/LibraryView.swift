import GRDB
import GRDBQuery
import Persistence
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Observes the library (`LibraryRequests.allBooks()`) for `@Query`.
struct AllBooksRequest: ValueObservationQueryable {
    static var defaultValue: [BookRecord] { [] }

    func fetch(_ db: Database) throws -> [BookRecord] {
        try LibraryRequests.allBooks().fetchAll(db)
    }
}

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(AllBooksRequest()) private var books: [BookRecord]

    @State private var importer = ImportCoordinator()
    @State private var isPickingFile = false
    @State private var openBook: BookRecord?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
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

    @ViewBuilder
    private var content: some View {
        if let error = $books.error {
            ContentUnavailableView {
                Label("Couldn't load your library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            }
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
            }
            .listStyle(.plain)
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
