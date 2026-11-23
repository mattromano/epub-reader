import Foundation
import Persistence

public struct ReadwisePushResult: Sendable, Equatable {
    /// Sent with `POST` (new, or changed without a known Readwise id).
    public var created: Int
    /// Sent with `PATCH`.
    public var updated: Int
    /// Refused by Readwise one by one; left pending and retried next push.
    public var rejected: Int

    public init(created: Int = 0, updated: Int = 0, rejected: Int = 0) {
        self.created = created
        self.updated = updated
        self.rejected = rejected
    }
}

/// Pushes new and changed highlights to Readwise (PLAN M7). One push at a time: a call while
/// another runs returns nil.
///
/// 1. `POST` every pending highlight without a known Readwise id, 100 per request. A rejected
///    batch is split in halves until the bad highlight is alone, so it can't block the rest.
/// 2. For each Readwise book those landed in, list its highlights and store the ids whose `url`
///    is one of ours (`margins://highlight/<uuid>`).
/// 3. `PATCH` text, note and color of changed highlights with a known id, including ones step 2
///    just resolved that were pushed before (a re-POST with unchanged text is a no-op in Readwise).
///    A 404 means it was deleted in Readwise: forget the id and `POST` it again.
///
/// A highlight is marked pushed (`export_readwise_at` = the push's start) once its last request
/// succeeds. Unauthorized, rate-limit and server errors stop the push; what already went is kept.
public actor ReadwisePusher {
    public static let batchSize = 100

    private let database: AppDatabase
    private var isRunning = false

    public init(database: AppDatabase) {
        self.database = database
    }

    public func push(client: ReadwiseClient, now: Date = Date()) async throws -> ReadwisePushResult? {
        guard !isRunning else { return nil }
        isRunning = true
        defer { isRunning = false }

        let pending = try await database.pendingReadwiseHighlights()
        var result = ReadwisePushResult()
        var books = Set<Int>()

        // 1. Create.
        let toCreate = pending.filter { $0.readwiseID == nil }
        var created: [ReadwisePendingHighlight] = []
        for start in stride(from: 0, to: toCreate.count, by: Self.batchSize) {
            let batch = Array(toCreate[start ..< min(start + Self.batchSize, toCreate.count)])
            try await create(batch, client: client, books: &books, created: &created, rejected: &result.rejected)
        }
        result.created = created.count
        // First-time highlights are done after the POST.
        try await database.markReadwiseExported(highlightIDs: created.filter { !$0.wasExported }.map(\.highlightID),
                                                at: now)

        // 2. Resolve ids.
        let resolved = try await resolveIDs(books: books, client: client, now: now)

        // 3. Update. Re-pushed highlights that still have no id: the POST is all that can be done.
        let reposted = created.filter(\.wasExported)
        try await database.markReadwiseExported(
            highlightIDs: reposted.filter { resolved[$0.highlightID] == nil }.map(\.highlightID), at: now)
        var toUpdate = pending.filter { $0.readwiseID != nil }
        toUpdate += reposted.compactMap { highlight in
            resolved[highlight.highlightID].map { id in
                var copy = highlight
                copy.readwiseID = id
                return copy
            }
        }
        for highlight in toUpdate {
            guard let id = highlight.readwiseID else { continue }
            do {
                try await client.updateHighlight(id: id, ReadwisePayload.update(highlight))
                try await database.markReadwiseExported(highlightIDs: [highlight.highlightID], at: now)
                result.updated += 1
            } catch ReadwiseError.notFound {
                try await database.clearReadwiseID(highlightID: highlight.highlightID)
                var recreated: [ReadwisePendingHighlight] = []
                var newBooks = Set<Int>()
                try await create([highlight], client: client, books: &newBooks, created: &recreated,
                                 rejected: &result.rejected)
                try await database.markReadwiseExported(highlightIDs: recreated.map(\.highlightID), at: now)
                result.created += recreated.count
            } catch ReadwiseError.rejected {
                result.rejected += 1
            }
        }
        return result
    }

    private func create(_ batch: [ReadwisePendingHighlight], client: ReadwiseClient, books: inout Set<Int>,
                        created: inout [ReadwisePendingHighlight], rejected: inout Int) async throws {
        guard !batch.isEmpty else { return }
        do {
            let response = try await client.createHighlights(batch.map(ReadwisePayload.create))
            books.formUnion(response.map(\.id))
            created += batch
        } catch ReadwiseError.rejected where batch.count > 1 {
            let middle = batch.count / 2
            try await create(Array(batch[..<middle]), client: client, books: &books, created: &created,
                             rejected: &rejected)
            try await create(Array(batch[middle...]), client: client, books: &books, created: &created,
                             rejected: &rejected)
        } catch ReadwiseError.rejected {
            rejected += 1
        }
    }

    /// Highlight id → Readwise id for our highlights in `books`, stored as found.
    private func resolveIDs(books: Set<Int>, client: ReadwiseClient, now: Date) async throws -> [String: Int] {
        var resolved: [String: Int] = [:]
        for book in books.sorted() {
            for listed in try await client.highlights(bookID: book) {
                if let highlightID = ReadwisePayload.highlightID(fromURL: listed.url) {
                    resolved[highlightID] = listed.id
                }
            }
        }
        try await database.setReadwiseIDs(resolved, now: now)
        return resolved
    }
}
