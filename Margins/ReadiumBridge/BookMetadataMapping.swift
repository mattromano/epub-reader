import Foundation
import Persistence
@preconcurrency import ReadiumShared

/// Book metadata extracted from a Readium `Publication`, as plain `Sendable` values.
struct ParsedPublication: Sendable, Equatable {
    var title: String
    var authorNames: [String]
    var identifier: String?
    var language: String?
    var publisher: String?
    var publishedDate: String?
    var layout: String
    var readingProgression: String
    var coverPNG: Data?

    nonisolated init(metadata: Metadata, coverPNG: Data?) {
        let trimmedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        authorNames = metadata.authors
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        identifier = metadata.identifier
        language = metadata.languages.first
        publisher = metadata.publishers.first?.name
        publishedDate = metadata.published.map(Self.isoDate)
        layout = metadata.layout == .fixed ? "fixed" : "reflowable"
        readingProgression = metadata.readingProgression == .rtl ? "rtl" : "ltr"
        self.coverPNG = coverPNG
    }

    /// The row handed to `AppDatabase.importBook`.
    func newBook(contentHash: String, fileRelpath: String, fileSizeBytes: Int, coverRelpath: String?) -> NewBook {
        NewBook(
            contentHash: contentHash,
            identifier: identifier,
            title: title,
            authors: authorNames.joined(separator: ", "),
            authorsJSON: Self.jsonArray(authorNames),
            language: language,
            publisher: publisher,
            publishedDate: publishedDate,
            epubVersion: nil, // Readium 3.11 doesn't expose the OPF package version publicly.
            layout: layout,
            readingProgression: readingProgression,
            fileRelpath: fileRelpath,
            fileSizeBytes: fileSizeBytes,
            coverRelpath: coverRelpath
        )
    }

    private static func jsonArray(_ values: [String]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    /// `yyyy-MM-dd` in UTC; publication dates are calendar dates, not instants.
    private static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }
}
