import Combine
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

/// Observes which stats the reader's tap panel and always-on line show.
struct ReaderStatsSettingsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: ReaderStatsSettings { .default }

    func fetch(_ db: Database) throws -> ReaderStatsSettings {
        try MetricsQueries.readerStatsSettings(db)
    }
}

/// Picks and orders the stats for the reader's tap panel and always-on line.
struct ReaderStatsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(ReaderStatsSettingsRequest()) private var settings: ReaderStatsSettings

    @State private var message: String?

    private var unchosenLineStats: [ReaderStat] {
        ReaderStat.allCases.filter { !settings.line.contains($0) }
    }

    /// Included stats in panel order, then the rest in canonical order.
    private var panelRows: [ReaderStat] {
        settings.panel + ReaderStat.allCases.filter { !settings.panel.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show line", isOn: lineEnabledBinding)
                ForEach(settings.line) { stat in
                    Text(stat.title)
                }
                .onMove { source, destination in
                    var next = settings
                    next.line.move(fromOffsets: source, toOffset: destination)
                    save(next)
                }
                .onDelete { offsets in
                    var next = settings
                    next.line.remove(atOffsets: offsets)
                    save(next)
                }
                ForEach(unchosenLineStats) { stat in
                    Button {
                        var next = settings
                        next.line.append(stat)
                        save(next)
                    } label: {
                        Label(stat.title, systemImage: "plus.circle")
                    }
                    .disabled(settings.line.count >= ReaderStatsSettings.maxLineStats)
                    .deleteDisabled(true)
                    .moveDisabled(true)
                }
            } header: {
                Text("Always-on line")
            } footer: {
                Text("Up to \(ReaderStatsSettings.maxLineStats). Shows under the page while you read. Turning it on or off applies the next time you open a book.")
            }

            Section {
                ForEach(panelRows) { stat in
                    Toggle(stat.title, isOn: panelBinding(for: stat))
                }
                .onMove { source, destination in
                    var rows = panelRows
                    rows.move(fromOffsets: source, toOffset: destination)
                    var next = settings
                    next.panel = rows.filter { settings.panel.contains($0) }
                    save(next)
                }
            } header: {
                Text("Tap panel")
            } footer: {
                Text("Shown when you tap the page. Stats without a value yet are left out.")
            }

            Section {
                Button("Reset to Defaults") { save(.default) }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Reader Stats")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reader Stats", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var lineEnabledBinding: Binding<Bool> {
        Binding(get: { settings.lineEnabled }, set: { newValue in
            var next = settings
            next.lineEnabled = newValue
            save(next)
        })
    }

    private func panelBinding(for stat: ReaderStat) -> Binding<Bool> {
        Binding(get: { settings.panel.contains(stat) }, set: { isOn in
            var next = settings
            if isOn {
                if !next.panel.contains(stat) { next.panel.append(stat) }
            } else {
                next.panel.removeAll { $0 == stat }
            }
            save(next)
        })
    }

    /// Writes both keys together; the observation then refreshes the view.
    private func save(_ next: ReaderStatsSettings) {
        let database = environment.database
        Task {
            do {
                try await database.setSettingJSON(next.encodedPanelJSON(), forKey: ReaderStatsSettings.panelKey)
                try await database.setSettingJSON(next.encodedLineJSON(), forKey: ReaderStatsSettings.lineKey)
            } catch {
                message = "The change couldn't be saved. \(error.localizedDescription)"
            }
        }
    }
}
