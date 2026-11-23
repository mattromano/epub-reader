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

/// The tab bar (SPEC §3). Each tab presents the reader itself.
private struct RootTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedTab") private var selectedTab = "library"

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "books.vertical", value: "library") {
                LibraryView()
            }
            Tab("Quotes", systemImage: "quote.opening", value: "quotes") {
                QuotesView()
            }
            Tab("Stats", systemImage: "chart.bar.xaxis", value: "stats") {
                StatsView()
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                SettingsView()
            }
        }
        // One handler for every URL; the Library tab acts on what it leaves in the environment.
        .onOpenURL { url in
            if environment.handle(url: url) { selectedTab = "library" }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            let widgets = environment.widgets
            Task { await widgets.publish() }
            environment.readwise.pushOnBackground()
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
