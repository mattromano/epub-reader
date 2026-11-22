import Foundation
@preconcurrency import ReadiumShared

/// Locator <-> JSON string, the only form in which a Readium `Locator` crosses into BookKit.
extension Locator {
    /// Deterministic JSON (sorted keys) for storage in `last_locator_json` etc.
    var storedJSONString: String? {
        try? jsonString()
    }

    /// Restores a stored locator. Returns nil (rather than throwing) for missing or corrupt JSON,
    /// so a bad row just means "start from the beginning".
    init?(storedJSONString json: String?) {
        guard let json, !json.isEmpty, let locator = try? Locator(jsonString: json) else {
            return nil
        }
        self = locator
    }
}

/// What `AppDatabase.updateResumePoint` needs, derived from a Readium `Locator`.
struct ResumePoint: Sendable, Equatable {
    var locatorJSON: String
    var totalProgression: Double

    init?(locator: Locator) {
        guard let json = locator.storedJSONString else {
            return nil
        }
        locatorJSON = json
        totalProgression = locator.locations.totalProgression ?? 0
    }
}
