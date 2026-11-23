import CoreTransferable
import Foundation
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// A zip of the whole library (database, EPUBs, covers), built when the share sheet asks for it.
/// "Save to Files" → iCloud Drive keeps a copy off the phone; the free tier has no sync.
struct LibraryBackupFile: Transferable {
    let database: AppDatabase
    let containerURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { file in
            let workDirectory = try ExportFiles.freshDirectory()
            let folder = try await LibraryBackup.makeFolder(
                database: file.database, container: file.containerURL, in: workDirectory)
            let zip = try LibraryBackup.zip(folder: folder)
            try? FileManager.default.removeItem(at: folder)
            return SentTransferredFile(zip)
        }
    }
}

struct BackupSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Section {
            ShareLink(
                item: LibraryBackupFile(database: environment.database, containerURL: environment.containerURL),
                preview: SharePreview("Margins Backup")
            ) {
                Label("Back Up Data", systemImage: "externaldrive.badge.icloud")
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Saves your books, highlights, reading history and settings as one zip. Choose Save to Files and pick iCloud Drive to keep a copy off this phone.")
        }
    }
}
