import Foundation
import Importing
import Observation
import Persistence

/// Runs the SPEC §3 import flow: copy (coordinated, security-scoped) → hash → dedupe →
/// move into `Books/<sha256>.epub` → parse with Readium → save cover → `importBook`.
@MainActor
@Observable
final class ImportCoordinator {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var isImporting = false
    var notice: Notice?

    func importBooks(from urls: [URL], environment: AppEnvironment) async {
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            await importBook(from: url, environment: environment)
        }
    }

    func importBook(from url: URL, environment: AppEnvironment) async {
        let database = environment.database
        let container = environment.containerURL
        let publications = environment.publications
        let filename = url.lastPathComponent

        // 1-4. Copy into a temp file (security-scoped access is held only for the copy), then hash.
        let staged: StagedFile
        do {
            staged = try await Task.detached(priority: .userInitiated) {
                try Self.stage(url)
            }.value
        } catch {
            notice = Notice(title: "Couldn't import \(filename)", message: "The file couldn't be read. \(error.localizedDescription)")
            return
        }

        // Dedupe before touching Books/: a duplicate must never overwrite or delete the existing file.
        do {
            if let existing = try await database.book(withContentHash: staged.contentHash) {
                Self.removeQuietly(staged.tempURL)
                notice = Notice(title: "Already in your library", message: "“\(existing.title)” is already in your library.")
                return
            }
        } catch {
            Self.removeQuietly(staged.tempURL)
            notice = Notice(title: "Couldn't import \(filename)", message: "The library couldn't be read. \(error.localizedDescription)")
            return
        }

        // 5. Move into place and parse with Readium (off the main actor).
        let bookRelpath = BookPaths.bookRelpath(contentHash: staged.contentHash)
        let coverRelpath = BookPaths.coverRelpath(contentHash: staged.contentHash)
        let bookURL = BookPaths.resolve(bookRelpath, in: container)
        let coverURL = BookPaths.resolve(coverRelpath, in: container)

        let parsed: ParsedPublication
        var createdFiles: [URL] = []
        do {
            try Self.moveIntoPlace(staged.tempURL, to: bookURL)
            createdFiles.append(bookURL)
            parsed = try await publications.parseForImport(at: bookURL)
        } catch {
            Self.removeQuietly(staged.tempURL)
            createdFiles.forEach(Self.removeQuietly)
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            notice = Notice(title: "Couldn't import \(filename)", message: reason)
            return
        }

        // Cover is optional: a failed write just means no thumbnail.
        var storedCoverRelpath: String?
        if let png = parsed.coverPNG, (try? Self.write(png, to: coverURL)) != nil {
            createdFiles.append(coverURL)
            storedCoverRelpath = coverRelpath
        }

        // 6. Insert dim_book (importBook dedupes by content_hash in one transaction; authoritative).
        let newBook = parsed.newBook(
            contentHash: staged.contentHash,
            fileRelpath: bookRelpath,
            fileSizeBytes: staged.sizeBytes,
            coverRelpath: storedCoverRelpath
        )
        do {
            switch try await database.importBook(newBook) {
            case let .inserted(book):
                environment.indexing.enqueue(bookID: book.id)
            case let .duplicate(existing):
                // Same hash => same Books/Covers paths as the existing row, so keep the files.
                notice = Notice(title: "Already in your library", message: "“\(existing.title)” is already in your library.")
            }
        } catch {
            createdFiles.forEach(Self.removeQuietly)
            notice = Notice(title: "Couldn't import \(filename)", message: "The library couldn't be updated. \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private struct StagedFile: Sendable {
        let tempURL: URL
        let contentHash: String
        let sizeBytes: Int
    }

    /// Copies the picked file into a temp location inside an `NSFileCoordinator` read, with
    /// security-scoped access balanced by `defer`, then hashes the copy.
    nonisolated private static func stage(_ source: URL) throws -> StagedFile {
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("epub")

        // Returns false for URLs that aren't security-scoped (e.g. some onOpenURL inbox copies);
        // the copy is still attempted.
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: source,
            options: [.withoutChanges],
            error: &coordinationError
        ) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: tempURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            removeQuietly(tempURL)
            throw error
        }

        do {
            let hash = try ContentHasher.sha256Hex(fileAt: tempURL)
            let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return StagedFile(tempURL: tempURL, contentHash: hash, sizeBytes: size)
        } catch {
            removeQuietly(tempURL)
            throw error
        }
    }

    nonisolated private static func moveIntoPlace(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // No live row owns this hash (checked above), so a file here is a leftover from a failed import.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    nonisolated private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    nonisolated private static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
