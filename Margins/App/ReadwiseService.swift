import Foundation
import Observation
import Persistence
import Readwise
import Security
import UIKit

/// The Readwise access token, stored only in the Keychain (CLAUDE.md: never in the DB or a log).
/// This device only: it doesn't sync through iCloud Keychain.
enum ReadwiseKeychain {
    private static let service = "com.mattromano.margins.readwise"
    private static let account = "token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The token couldn't be saved in the Keychain (error \(status))." }
    }
}

/// Connects a Readwise token and pushes highlights (PLAN M7): on demand from Settings, and when
/// the app goes to the background.
@MainActor
@Observable
final class ReadwiseService {
    private(set) var isConnected: Bool
    private(set) var isPushing = false
    /// Bumped after every push, so Settings re-reads the status.
    private(set) var pushCount = 0

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let pusher: ReadwisePusher

    init(database: AppDatabase) {
        self.database = database
        pusher = ReadwisePusher(database: database)
        isConnected = ReadwiseKeychain.token() != nil
    }

    /// Checks the token with Readwise, then stores it. Throws with a user-facing message.
    func connect(token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ReadwiseServiceError.emptyToken }
        guard try await ReadwiseClient(token: token).validateToken() else { throw ReadwiseError.unauthorized }
        try ReadwiseKeychain.save(token)
        isConnected = true
    }

    func disconnect() {
        ReadwiseKeychain.delete()
        isConnected = false
    }

    func status() async throws -> ReadwiseStatus {
        try await database.readwiseStatus()
    }

    /// Push from Settings. Returns what happened, for an alert.
    func pushNow() async -> String {
        guard let token = ReadwiseKeychain.token() else { return "Connect Readwise first." }
        isPushing = true
        defer {
            isPushing = false
            pushCount += 1
        }
        do {
            guard let result = try await pusher.push(client: ReadwiseClient(token: token)) else {
                return "A push is already running."
            }
            return Self.describe(result)
        } catch ReadwiseError.unauthorized {
            return "Readwise didn't accept the token. Reconnect in Settings."
        } catch {
            return error.localizedDescription
        }
    }

    /// Push when the app goes to the background, inside a background task. Rate-limit waits
    /// longer than a few seconds end the push instead; the rest goes next time.
    func pushOnBackground() {
        guard let token = ReadwiseKeychain.token(), backgroundTaskID == .invalid else { return }
        let pushTask = Task { [pusher] in
            _ = try? await pusher.push(client: ReadwiseClient(token: token, maxRetryWait: 5, maxRetries: 1))
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Readwise push") { [weak self] in
            pushTask.cancel()
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        Task { [weak self] in
            _ = await pushTask.result
            self?.pushCount += 1
            self?.endBackgroundTask()
        }
    }

    @ObservationIgnored private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private static func describe(_ result: ReadwisePushResult) -> String {
        if result == ReadwisePushResult() { return "Everything is already in Readwise." }
        var parts: [String] = []
        if result.created > 0 { parts.append("\(result.created) sent") }
        if result.updated > 0 { parts.append("\(result.updated) updated") }
        var message = parts.joined(separator: ", ") + "."
        if result.rejected > 0 {
            message += " Readwise refused \(result.rejected); \(result.rejected == 1 ? "it stays" : "they stay") pending."
        }
        return message.prefix(1).uppercased() + message.dropFirst()
    }
}

enum ReadwiseServiceError: LocalizedError {
    case emptyToken
    var errorDescription: String? { "Paste your Readwise access token." }
}
