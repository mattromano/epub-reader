import CoreTransferable
import Exporting
import Foundation
import GRDB
import Persistence
import UniformTypeIdentifiers

/// Export files (SPEC §10), produced lazily when the share sheet asks for them: each one reads
/// the database, writes a temp file, and hands it over. Used with `ShareLink`.
enum ExportFiles {
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText

    /// A fresh, empty temp directory, so concurrent exports never collide on a file name.
    static func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Every highlight in the library as one CSV.
struct HighlightsCSVFile: Transferable {
    let database: AppDatabase

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            let quotes = try await file.database.reader.read { db in
                try QuoteRequests.quotes(QuoteFilter(sort: .book)).fetchAll(db)
            }
            let url = try ExportFiles.freshDirectory()
                .appendingPathComponent(ExportFileName.make("Margins highlights", ext: "csv"))
            try CSVExport.data(quotes).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// One book's highlights as Obsidian-style Markdown.
struct BookMarkdownFile: Transferable {
    let database: AppDatabase
    let bookID: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: ExportFiles.markdownType) { file in
            let bookID = file.bookID
            let (book, quotes) = try await file.database.reader.read { db in
                let book = try BookRecord.fetchOne(db, key: bookID)
                let quotes = try QuoteRequests.quotes(QuoteFilter(bookID: bookID, sort: .book)).fetchAll(db)
                return (book, quotes)
            }
            guard let book else { throw CocoaError(.fileNoSuchFile) }
            let url = try ExportFiles.freshDirectory()
                .appendingPathComponent(ExportFileName.make(book.title, ext: "md"))
            try Data(MarkdownExport.book(book, quotes: quotes).utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
