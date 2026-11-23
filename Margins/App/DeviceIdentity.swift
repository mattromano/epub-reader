import Foundation
import UIKit

/// This device's `dim_device.device_id`. Kept in App Group `UserDefaults`, not `app_setting`:
/// that table syncs, and the id must stay per device (PLAN M2 decisions).
enum DeviceIdentity {
    static let defaultsKey = "deviceID"

    /// The stored id, created (and stored) on first use.
    @MainActor
    static var deviceID: String {
        let defaults = UserDefaults(suiteName: AppEnvironment.appGroupIdentifier) ?? .standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: defaultsKey)
        return created
    }

    @MainActor
    static var name: String { UIDevice.current.name }

    @MainActor
    static var model: String { UIDevice.current.model }
}
