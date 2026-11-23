import GRDBQuery
import SwiftUI

@main
struct MarginsApp: App {
    @State private var startup: Startup

    init() {
        let result: Startup
        do {
            result = .ready(try AppEnvironment.make())
        } catch {
            result = .failed(error.localizedDescription)
        }
        _startup = State(initialValue: result)
    }

    var body: some Scene {
        WindowGroup {
            switch startup {
            case let .ready(environment):
                RootTabView()
                    .environment(environment)
                    .databaseContext(.readOnly { environment.database.reader })
                    // Runs after the first frame; guarded inside so it happens once per launch.
                    .task { await environment.runLaunchTasks() }
            case let .failed(message):
                StartupErrorView(message: message)
            }
        }
    }
}

/// The tab bar (SPEC §3). Stats and Settings join in M5. Each tab presents the reader itself.
private struct RootTabView: View {
    @SceneStorage("selectedTab") private var selectedTab = "library"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: "library") {
                LibraryView()
            }
            Tab("Quotes", systemImage: "quote.opening", value: "quotes") {
                QuotesView()
            }
        }
    }
}

private enum Startup {
    case ready(AppEnvironment)
    case failed(String)
}

/// Shown instead of crashing when the database can't be opened.
private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Margins couldn't open its library", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}
