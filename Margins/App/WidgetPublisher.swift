import Foundation
import Metrics
import Persistence
import WidgetData
import WidgetKit

/// Writes `widget_snapshot.json` to the App Group container and reloads the widget (PLAN M6).
/// Called after a reading session ends, on launch and when the app backgrounds. Foreground
/// reloads don't count against WidgetKit's daily budget.
struct WidgetPublisher: Sendable {
    let containerURL: URL
    let database: AppDatabase

    func publish(now: Date = Date()) async {
        do {
            let snapshot = try await database.reader.read { db in
                try MetricsQueries.widgetSnapshot(db, now: now)
            }
            try snapshot.write(to: containerURL)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            // Non-fatal: the widget keeps its previous snapshot until the next publish.
        }
    }
}
