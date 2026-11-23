import Combine
import GRDB
import GRDBQuery
import Metrics
import Persistence
import SwiftUI

struct PersonalBestsRequest: ValueObservationQueryable, Equatable, Hashable {
    static var defaultValue: [PersonalRecord] { [] }

    func fetch(_ db: Database) throws -> [PersonalRecord] {
        let today = try MetricsQueries.today(db)
        return try MetricsQueries.personalRecords(
            db, today: today, minMinutes: try AppDatabase.streakMinMinutes(db))
    }
}

struct PersonalBestsView: View {
    @Query(constant: PersonalBestsRequest()) private var records: [PersonalRecord]

    var body: some View {
        List {
            if records.isEmpty {
                Text("Read a bit to set your first records.")
                    .foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(record.kind))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(record.kind))
                        if let subtitle = Self.subtitle(record) {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Self.value(record))
                        .font(.headline)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Personal bests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func symbol(_ kind: PersonalRecordKind) -> String {
        switch kind {
        case .longestSession: "timer"
        case .fastestSession: "hare"
        case .mostMinutesInDay: "calendar.badge.clock"
        case .mostWordsInDay: "text.word.spacing"
        case .mostPagesInSession: "book.pages"
        case .longestStreak: "flame"
        }
    }

    private static func title(_ kind: PersonalRecordKind) -> String {
        switch kind {
        case .longestSession: "Longest session"
        case .fastestSession: "Fastest session"
        case .mostMinutesInDay: "Most time in a day"
        case .mostWordsInDay: "Most words in a day"
        case .mostPagesInSession: "Most pages in a session"
        case .longestStreak: "Longest streak"
        }
    }

    private static func value(_ record: PersonalRecord) -> String {
        let whole = Int(record.value.rounded())
        switch record.kind {
        case .longestSession: return ReadingTimeFormat.minutes(record.value / 60)
        case .fastestSession: return "\(whole) wpm"
        case .mostMinutesInDay: return ReadingTimeFormat.minutes(record.value)
        case .mostWordsInDay: return "\(whole.formatted()) words"
        case .mostPagesInSession: return "\(whole.formatted()) pages"
        case .longestStreak: return whole == 1 ? "1 day" : "\(whole) days"
        }
    }

    /// "Nov 3 · Book title"; either half may be missing.
    private static func subtitle(_ record: PersonalRecord) -> String? {
        var parts: [String] = []
        if let localDate = record.localDate, let date = StatsDates.date(localDate) {
            parts.append(StatsDates.short(date))
        }
        if let title = record.bookTitle, !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
