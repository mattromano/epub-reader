import Foundation
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer

/// User-facing failures when opening a book file with Readium.
enum PublicationOpeningError: LocalizedError, Equatable {
    case fileMissing
    case notAnEPUB
    case unreadable
    case restricted

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            "The book file is missing. Try importing it again."
        case .notAnEPUB:
            "This file isn't a supported EPUB."
        case .unreadable:
            "This EPUB is damaged or malformed and can't be opened."
        case .restricted:
            "This book is DRM-protected. Margins only reads DRM-free EPUBs."
        }
    }
}

/// Wraps Readium's `AssetRetriever` + `PublicationOpener` (see the "Open Publication" guide).
///
/// Readium 3.x types are not `Sendable`, so each call builds its own retriever/opener and the
/// struct itself holds no state. Methods are `nonisolated` and `async`, so they run off the
/// main actor.
struct PublicationOpening: Sendable {
    /// Opens a local EPUB for rendering. The caller owns the result and must `close()` it.
    nonisolated func openPublication(at fileURL: URL) async throws -> Publication {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PublicationOpeningError.fileMissing
        }
        guard let url = FileURL(url: fileURL) else {
            throw PublicationOpeningError.unreadable
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        let asset: Asset
        switch await assetRetriever.retrieve(url: url) {
        case let .success(retrieved):
            asset = retrieved
        case .failure(.formatNotSupported), .failure(.schemeNotSupported):
            throw PublicationOpeningError.notAnEPUB
        case .failure(.reading):
            throw PublicationOpeningError.unreadable
        }

        let publication: Publication
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case let .success(opened):
            publication = opened
        case .failure(.formatNotSupported):
            asset.close()
            throw PublicationOpeningError.notAnEPUB
        case .failure(.reading):
            asset.close()
            throw PublicationOpeningError.unreadable
        }

        guard publication.conforms(to: .epub) else {
            publication.close()
            throw PublicationOpeningError.notAnEPUB
        }
        guard !publication.isRestricted else {
            publication.close()
            throw PublicationOpeningError.restricted
        }
        return publication
    }

    /// Opens, extracts metadata and cover, then closes. Only `Sendable` values leave this call.
    nonisolated func parseForImport(at fileURL: URL) async throws -> ParsedPublication {
        let publication = try await openPublication(at: fileURL)
        defer { publication.close() }

        let coverPNG = await CoverExtraction.coverPNG(of: publication)
        return ParsedPublication(metadata: publication.metadata, coverPNG: coverPNG)
    }
}
