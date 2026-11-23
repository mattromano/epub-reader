import Foundation
import Importing
import Observation
import Persistence
import WidgetData

/// App-wide dependencies, built once at launch and injected through the SwiftUI environment.
@MainActor
@Observable
final class AppEnvironment {
    nonisolated static let appGroupIdentifier = "group.com.mattromano.margins"

    /// Root that every stored relative path (`Books/…`, `Covers/…`, `Database/…`) resolves against.
    let containerURL: URL
    let database: AppDatabase
    let publications: PublicationOpening
    let indexing: IndexingService
    /// This device's `dim_device.device_id` (App Group `UserDefaults`).
    let deviceID: String
    let widgets: WidgetPublisher
    /// Set by a widget deep link (`margins://open?book=`); the Library tab opens the reader.
    var pendingOpenBookID: String?
    /// An EPUB handed to the app ("Open in…"); the Library tab imports it.
    var pendingImportURL: URL?

    @ObservationIgnored private var didRunLaunchTasks = false

    init(containerURL: URL, database: AppDatabase, publications: PublicationOpening) {
        self.containerURL = containerURL
        self.database = database
        self.publications = publications
        indexing = IndexingService(database: database, publications: publications, containerURL: containerURL)
        deviceID = DeviceIdentity.deviceID
        widgets = WidgetPublisher(containerURL: containerURL, database: database)
    }

    /// Routes every URL the app is opened with: widget deep links and EPUB files.
    /// Returns true if the Library tab should come forward.
    func handle(url: URL) -> Bool {
        if let bookID = WidgetLink.bookID(from: url) {
            pendingOpenBookID = bookID
            return true
        }
        if url.isFileURL {
            pendingImportURL = url
            return true
        }
        return false
    }

    /// Once per launch, after the first frame: device row, crash recovery of unfinished
    /// sessions, then background indexing of books that need it. Each step is best-effort.
    func runLaunchTasks() async {
        guard !didRunLaunchTasks else { return }
        didRunLaunchTasks = true
        do {
            try await database.ensureDevice(id: deviceID, name: DeviceIdentity.name, model: DeviceIdentity.model)
        } catch {
            // Non-fatal: sessions still carry the device id.
        }
        do {
            try await database.recoverDrafts()
        } catch {
            // Non-fatal: drafts stay and are retried next launch.
        }
        await widgets.publish()
        await indexing.indexPendingOnLaunch()
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
