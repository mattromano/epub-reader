import Foundation
import Importing
import Observation
import Persistence

/// App-wide dependencies, built once at launch and injected through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    nonisolated static let appGroupIdentifier = "group.com.mattromano.margins"

    /// Root that every stored relative path (`Books/…`, `Covers/…`, `Database/…`) resolves against.
    let containerURL: URL
    let database: AppDatabase
    let publications: PublicationOpening

    init(containerURL: URL, database: AppDatabase, publications: PublicationOpening) {
        self.containerURL = containerURL
        self.database = database
        self.publications = publications
    }

    enum ContainerError: LocalizedError {
        case appGroupUnavailable
        var errorDescription: String? {
            "The app's shared storage (App Group \(AppEnvironment.appGroupIdentifier)) isn't available. Check the App Group capability and signing team in Xcode, then reinstall."
        }
    }

    /// Opens the database in the App Group container. Only unsigned simulator builds fall back
    /// to Application Support; on a device a missing App Group is an error, so the library
    /// never silently lands outside the container (and then "disappears" once signing is fixed).
    static func make() throws -> AppEnvironment {
        let container = try resolveContainerURL()
        let databaseURL = BookPaths.resolve(BookPaths.databaseRelpath, in: container)
        let database = try AppDatabase.open(at: databaseURL)
        return AppEnvironment(containerURL: container, database: database, publications: PublicationOpening())
    }

    func resolve(_ relpath: String) -> URL {
        BookPaths.resolve(relpath, in: containerURL)
    }

    private static func resolveContainerURL() throws -> URL {
        let fileManager = FileManager.default
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return groupURL
        }
        #if !targetEnvironment(simulator)
        throw ContainerError.appGroupUnavailable
        #else
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let fallback = support.appendingPathComponent("Margins", isDirectory: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
        #endif
    }
}
