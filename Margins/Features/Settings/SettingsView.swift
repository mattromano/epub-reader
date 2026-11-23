import Combine
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

/// Observes the current daily-minutes goal (SCD2 row with no `valid_to`).
struct CurrentGoalRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: GoalRecord? { nil }

    func fetch(_ db: Database) throws -> GoalRecord? {
        try GoalRequests.current(.dailyMinutes).fetchOne(db)
    }
}

/// Goals, reading-day boundary, streak minimum and "Rebuild stats" (PLAN M5).
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(CurrentGoalRequest()) private var goal: GoalRecord?

    @State private var dayStartHour = ReadingDays.defaultDayStartHour
    @State private var streakMinMinutes = 5.0
    @State private var didLoad = false
    @State private var isRebuilding = false
    @State private var message: String?

    private var goalMinutes: Int { Int((goal?.target ?? 30).rounded()) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: goalBinding, in: 5 ... 240, step: 5) {
                        LabeledContent("Daily goal", value: "\(goalMinutes) min")
                    }
                } header: {
                    Text("Goals")
                } footer: {
                    Text("A change applies from today. Past days keep the goal they had.")
                }

                Section {
                    Stepper(value: streakBinding, in: 1 ... 60) {
                        LabeledContent("Streak minimum", value: "\(Int(streakMinMinutes)) min")
                    }
                    Picker("Day starts at", selection: dayStartBinding) {
                        ForEach(0 ... 6, id: \.self) { hour in
                            Text(Self.hourLabel(hour)).tag(hour)
                        }
                    }
                } header: {
                    Text("Streaks")
                } footer: {
                    Text("Reading before this hour counts toward the previous day. A new hour applies to new sessions only.")
                }

                Section {
                    NavigationLink("Reader Stats") { ReaderStatsSettingsView() }
                } footer: {
                    Text("Choose the stats shown while you read.")
                }

                ReadwiseSettingsSection()

                BackupSettingsSection()

                Section {
                    Button {
                        rebuild()
                    } label: {
                        HStack {
                            Text("Rebuild Stats")
                            if isRebuilding {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRebuilding)
                } footer: {
                    Text("Recomputes daily and per-book totals from your reading sessions.")
                }
            }
            .navigationTitle("Settings")
            .task { await load() }
            .alert("Settings", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var goalBinding: Binding<Int> {
        Binding(get: { goalMinutes }, set: { newValue in
            let database = environment.database
            Task {
                do {
                    let today = try await database.reader.read { try MetricsQueries.today($0) }
                    try await database.setGoal(.dailyMinutes, target: Double(newValue), effectiveFrom: today)
                } catch {
                    message = "The goal couldn't be saved. \(error.localizedDescription)"
                }
            }
        })
    }

    private var streakBinding: Binding<Double> {
        Binding(get: { streakMinMinutes }, set: { newValue in
            streakMinMinutes = newValue
            let database = environment.database
            Task { try? await database.setStreakMinMinutes(newValue) }
        })
    }

    private var dayStartBinding: Binding<Int> {
        Binding(get: { dayStartHour }, set: { newValue in
            dayStartHour = newValue
            let database = environment.database
            Task { try? await database.setDayStartHour(newValue) }
        })
    }

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        let database = environment.database
        if let hour = try? await database.dayStartHour() { dayStartHour = hour }
        if let minutes = try? await database.streakMinMinutes() { streakMinMinutes = minutes }
    }

    private func rebuild() {
        isRebuilding = true
        let database = environment.database
        Task {
            do {
                try await database.rebuildAggregates()
                message = "Stats rebuilt."
            } catch {
                message = "Stats couldn't be rebuilt. \(error.localizedDescription)"
            }
            isRebuilding = false
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        hour == 0 ? "Midnight" : Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)
            .map { $0.formatted(date: .omitted, time: .shortened) } ?? "\(hour):00"
    }
}
