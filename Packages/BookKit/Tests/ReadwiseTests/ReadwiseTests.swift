import Foundation
import GRDB
import Testing
@testable import Persistence
@testable import Readwise

private let t0 = Timestamp.date(from: "2026-11-22T10:00:00.000Z")!
private func at(_ offset: Double) -> Date { t0.addingTimeInterval(offset) }

private func pending(_ id: String = "h1", quote: String = "a quote", note: String = "", tags: [String] = [],
                     wordIdx: Int? = 42, readwiseID: Int? = nil, wasExported: Bool = false,
                     color: String? = "green") -> ReadwisePendingHighlight {
    ReadwisePendingHighlight(highlightID: id, bookTitle: "Middlemarch", bookAuthors: "George Eliot", quote: quote,
                             note: note, color: color, wordIdx: wordIdx, createdAt: "2026-11-22T10:00:00.000Z",
                             tags: tags, readwiseID: readwiseID, wasExported: wasExported)
}

// MARK: - Payload

@Suite struct ReadwisePayloadTests {
    @Test func createMapsFields() throws {
        let payload = ReadwisePayload.create(pending(quote: "  It is a truth.\n", note: "Nice", tags: ["Work"]))
        #expect(payload.text == "It is a truth.")
        #expect(payload.title == "Middlemarch")
        #expect(payload.author == "George Eliot")
        #expect(payload.category == "books")
        #expect(payload.location == 42)
        #expect(payload.locationType == "order")
        #expect(payload.highlightedAt == "2026-11-22T10:00:00.000Z")
        #expect(payload.highlightURL == "margins://highlight/h1")
        #expect(payload.sourceType == "margins")
        #expect(payload.note == ".Work\nNice")

        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(json.contains("\"highlight_url\":\"margins:\\/\\/highlight\\/h1\""))
        #expect(json.contains("\"location_type\":\"order\""))
        #expect(json.contains("\"source_type\":\"margins\""))
    }

    @Test func noteIsNilWithoutNoteOrTags() {
        #expect(ReadwisePayload.create(pending()).note == nil)
        #expect(ReadwisePayload.create(pending(note: "  ")).note == nil)
        #expect(ReadwisePayload.create(pending(tags: ["a"])).note == ".a")
    }

    @Test func tagLineMakesOneWordTokens() {
        #expect(ReadwisePayload.tagLine(["Big Idea", "big idea", "c++", "to-do", "!!"]) == ".Big-Idea .c .to-do")
    }

    @Test func emptyTitleAndAuthor() {
        var highlight = pending()
        highlight.bookTitle = " "
        highlight.bookAuthors = ""
        let payload = ReadwisePayload.create(highlight)
        #expect(payload.title == "Untitled")
        #expect(payload.author == nil)
    }

    @Test func clipsOnCharacterBoundaries() {
        #expect(ReadwisePayload.clip("abc", 5) == "abc")
        #expect(ReadwisePayload.clip("ab😀c", 3) == "ab")
        #expect(ReadwisePayload.create(pending(quote: String(repeating: "x", count: 9000))).text.count == 8191)
    }

    @Test func updateSendsNoteWithoutTagsAndKnownColor() {
        let update = ReadwisePayload.update(pending(note: " edited ", tags: ["x"], color: "purple"))
        #expect(update == ReadwiseUpdateHighlight(text: "a quote", note: "edited", color: "purple"))
        #expect(ReadwisePayload.update(pending(color: nil)).color == "yellow")
        #expect(ReadwisePayload.update(pending(color: "teal")).color == "yellow")
    }

    @Test func highlightURLRoundTrips() {
        #expect(ReadwisePayload.highlightID(fromURL: ReadwisePayload.highlightURL("abc")) == "abc")
        #expect(ReadwisePayload.highlightID(fromURL: "https://example.com/x") == nil)
        #expect(ReadwisePayload.highlightID(fromURL: "margins://highlight/") == nil)
        #expect(ReadwisePayload.highlightID(fromURL: nil) == nil)
    }
}

// MARK: - Pending query

private func seededDatabase() async throws -> (AppDatabase, bookID: String) {
    let db = try AppDatabase.inMemory()
    let result = try await db.importBook(NewBook(contentHash: "hash-1", title: "Middlemarch", authors: "George Eliot",
                                                 fileRelpath: "Books/hash-1.epub", fileSizeBytes: 1), now: at(0))
    guard case let .inserted(book) = result else { throw ReadwiseError.badResponse }
    return (db, book.id)
}

private func save(_ db: AppDatabase, book: String, quote: String = "quote", note: String = "",
                  offset: Double = 1) async throws -> HighlightRecord {
    try await db.saveHighlight(NewHighlight(bookID: book, quoteExact: quote, wordIdx: 10, locatorJSON: "{}",
                                            note: note), now: at(offset))
}

@Suite struct ReadwiseMigrationTests {
    @Test func v7CreatesLocalMapTableOnly() throws {
        let db = try AppDatabase.inMemory()
        try db.reader.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(readwise_highlight)").map { $0["name"] as String }
            #expect(columns == ["highlight_id", "readwise_highlight_id", "updated_at"])
            let highlightColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(fact_highlight)")
                .map { $0["name"] as String }
            #expect(!highlightColumns.contains("readwise_highlight_id"))
            #expect(highlightColumns.contains("export_readwise_at"))
        }
    }
}

@Suite struct ReadwisePendingTests {
    @Test func newHighlightsArePendingInCreationOrder() async throws {
        let (db, book) = try await seededDatabase()
        let first = try await save(db, book: book, quote: "first", offset: 1)
        let second = try await save(db, book: book, quote: "second", offset: 2)
        _ = try await db.addTag(name: "Work", toHighlight: second.id, now: at(3))
        _ = try await db.addTag(name: "art", toHighlight: second.id, now: at(3))

        let rows = try await db.pendingReadwiseHighlights()
        #expect(rows.map(\.highlightID) == [first.id, second.id])
        #expect(rows[1].tags == ["art", "Work"])
        #expect(rows[1].bookTitle == "Middlemarch")
        #expect(rows[1].wasExported == false)
        #expect(rows[1].readwiseID == nil)
        #expect(try await db.readwiseStatus() == ReadwiseStatus(pendingCount: 2, lastPushAt: nil))
    }

    @Test func exportedThenEditedIsPendingAgain() async throws {
        let (db, book) = try await seededDatabase()
        let highlight = try await save(db, book: book, offset: 1)
        try await db.markReadwiseExported(highlightIDs: [highlight.id], at: at(5))
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
        #expect(try await db.readwiseStatus().lastPushAt == Timestamp.string(from: at(5)))

        try await db.updateHighlight(id: highlight.id, note: "later", now: at(6))
        try await db.setReadwiseIDs([highlight.id: 777], now: at(6))
        let rows = try await db.pendingReadwiseHighlights()
        #expect(rows.count == 1)
        #expect(rows[0].note == "later")
        #expect(rows[0].wasExported)
        #expect(rows[0].readwiseID == 777)
    }

    @Test func editDuringPushStaysPending() async throws {
        let (db, book) = try await seededDatabase()
        let highlight = try await save(db, book: book, offset: 1)
        // The push started at 5; the edit at 6 lands before the push marks it.
        try await db.updateHighlight(id: highlight.id, note: "mid-push", now: at(6))
        try await db.markReadwiseExported(highlightIDs: [highlight.id], at: at(5))
        #expect(try await db.pendingReadwiseHighlights().count == 1)
    }

    @Test func markingDoesNotBumpUpdatedAt() async throws {
        let (db, book) = try await seededDatabase()
        let highlight = try await save(db, book: book, offset: 1)
        try await db.markReadwiseExported(highlightIDs: [highlight.id], at: at(5))
        let stored = try await db.reader.read { try HighlightRequests.highlight(id: highlight.id).fetchOne($0) }
        #expect(stored?.updatedAt == highlight.updatedAt)
    }

    @Test func excludesDeletedBlankAndDeletedBook() async throws {
        let (db, book) = try await seededDatabase()
        let deleted = try await save(db, book: book, offset: 1)
        try await db.softDeleteHighlight(id: deleted.id, now: at(2))
        _ = try await save(db, book: book, quote: " \n ", offset: 3)
        let other = try await db.importBook(NewBook(contentHash: "hash-2", title: "Gone", authors: "",
                                                    fileRelpath: "Books/hash-2.epub", fileSizeBytes: 1), now: at(0))
        guard case let .inserted(gone) = other else { throw ReadwiseError.badResponse }
        _ = try await save(db, book: gone.id, offset: 4)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE dim_book SET deleted_at = ? WHERE book_id = ?",
                           arguments: [Timestamp.string(from: at(5)), gone.id])
        }
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
    }

    @Test func readwiseIDsUpsertAndClear() async throws {
        let (db, book) = try await seededDatabase()
        let highlight = try await save(db, book: book)
        try await db.setReadwiseIDs([highlight.id: 1], now: at(2))
        try await db.setReadwiseIDs([highlight.id: 2], now: at(3))
        #expect(try await db.pendingReadwiseHighlights().first?.readwiseID == 2)
        try await db.clearReadwiseID(highlightID: highlight.id)
        #expect(try await db.pendingReadwiseHighlights().first?.readwiseID == nil)
    }
}

// MARK: - Fake Readwise

private struct Reply: Sendable {
    var status: Int
    var body: String = ""
    var headers: [String: String] = [:]
}

/// Records requests and answers with `handler`.
private actor FakeTransport: ReadwiseTransport {
    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> Reply

    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = handler(request, requests.count)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    func summary() -> [String] {
        requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }
    }
}

private actor SleepLog {
    private(set) var waits: [Double] = []
    func add(_ wait: Double) { waits.append(wait) }
}

private func body(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

private func postedURLs(_ request: URLRequest) -> [String] {
    ((body(request)["highlights"] as? [[String: Any]]) ?? []).compactMap { $0["highlight_url"] as? String }
}

@Suite struct ReadwiseClientTests {
    @Test func validateTokenSendsTokenHeader() async throws {
        let transport = FakeTransport { request, _ in
            Reply(status: request.value(forHTTPHeaderField: "Authorization") == "Token secret" ? 204 : 401)
        }
        #expect(try await ReadwiseClient(token: "secret", transport: transport).validateToken())
        #expect(try await ReadwiseClient(token: "wrong", transport: transport).validateToken() == false)
        #expect(await transport.summary() == ["GET /api/v2/auth", "GET /api/v2/auth"])
    }

    @Test func retriesAfterRateLimit() async throws {
        let transport = FakeTransport { _, n in
            n < 3 ? Reply(status: 429, headers: ["Retry-After": "2"]) : Reply(status: 204)
        }
        let sleeps = SleepLog()
        let client = ReadwiseClient(token: "t", transport: transport, sleep: { await sleeps.add($0) })
        #expect(try await client.validateToken())
        #expect(await sleeps.waits == [2, 2])
    }

    @Test func longRetryAfterThrowsWithoutSleeping() async throws {
        let transport = FakeTransport { _, _ in Reply(status: 429, headers: ["Retry-After": "120"]) }
        let sleeps = SleepLog()
        let client = ReadwiseClient(token: "t", transport: transport, maxRetryWait: 25,
                                    sleep: { await sleeps.add($0) })
        await #expect(throws: ReadwiseError.rateLimited(retryAfter: 120)) { try await client.validateToken() }
        #expect(await sleeps.waits.isEmpty)
    }

    @Test func urlsKeepTrailingSlashes() async throws {
        let transport = FakeTransport { request, _ in
            switch request.httpMethod {
            case "POST": Reply(status: 200, body: "[]")
            case "GET" where request.url!.path.hasPrefix("/api/v2/highlights"):
                Reply(status: 200, body: #"{"next":null,"results":[]}"#)
            default: Reply(status: request.url!.path.hasSuffix("auth") ? 204 : 200, body: "{}")
            }
        }
        let client = ReadwiseClient(token: "t", transport: transport)
        _ = try await client.validateToken()
        _ = try await client.createHighlights([])
        try await client.updateHighlight(id: 12, ReadwiseUpdateHighlight(text: "t", note: "", color: "yellow"))
        _ = try await client.highlights(bookID: 9)
        #expect(await transport.requests.map { $0.url!.absoluteString } == [
            "https://readwise.io/api/v2/auth/",
            "https://readwise.io/api/v2/highlights/",
            "https://readwise.io/api/v2/highlights/12/",
            "https://readwise.io/api/v2/highlights/?book_id=9&page_size=1000",
        ])
    }

    @Test func createRequiresAnArrayBody() async throws {
        let transport = FakeTransport { _, _ in Reply(status: 200, body: #"{"count":0,"results":[]}"#) }
        await #expect(throws: ReadwiseError.badResponse) {
            try await ReadwiseClient(token: "t", transport: transport).createHighlights([])
        }
    }

    @Test func errorsDontLeakTheToken() {
        let errors: [ReadwiseError] = [.unauthorized, .rateLimited(retryAfter: 3), .notFound, .rejected(status: 400),
                                       .server(status: 500), .badResponse]
        for error in errors {
            #expect(!(error.errorDescription ?? "").contains("Token"))
        }
    }

    @Test func listFollowsPagesOnReadwiseOnly() async throws {
        let transport = FakeTransport { request, _ in
            if request.url!.query?.contains("page=2") == true {
                return Reply(status: 200, body: #"{"next":null,"results":[{"id":2,"url":null}]}"#)
            }
            return Reply(status: 200, body: """
                {"next":"https://readwise.io/api/v2/highlights/?book_id=9&page=2","results":[{"id":1,"url":"margins://highlight/a"}]}
                """)
        }
        let client = ReadwiseClient(token: "t", transport: transport)
        #expect(try await client.highlights(bookID: 9).map(\.id) == [1, 2])

        let evil = FakeTransport { _, _ in
            Reply(status: 200, body: #"{"next":"https://evil.example/steal","results":[]}"#)
        }
        await #expect(throws: ReadwiseError.badResponse) {
            try await ReadwiseClient(token: "t", transport: evil).highlights(bookID: 9)
        }
        #expect(await evil.requests.count == 1)
    }
}

// MARK: - Push

/// A tiny in-memory Readwise: one book (id 9), highlights keyed by `highlight_url`, deduped on text
/// like the real one (a re-POST with the same text doesn't change the note).
private final class FakeReadwise: @unchecked Sendable {
    struct Stored { var id: Int; var text: String; var note: String; var color: String }
    private let lock = NSLock()
    private var byURL: [String: Stored] = [:]
    private var nextID = 100
    var rejectText: String?
    var deletedIDs: Set<Int> = []

    func stored(_ highlightID: String) -> Stored? {
        lock.withLock { byURL[ReadwisePayload.highlightURL(highlightID)] }
    }

    func handle(_ request: URLRequest) -> Reply {
        lock.withLock {
            let path = request.url!.path
            switch (request.httpMethod, path) {
            case ("POST", "/api/v2/highlights"):
                let items = (body(request)["highlights"] as? [[String: Any]]) ?? []
                if let reject = rejectText, items.contains(where: { $0["text"] as? String == reject }) {
                    return Reply(status: 400, body: "{}")
                }
                var modified: [Int] = []
                for item in items {
                    let url = item["highlight_url"] as! String
                    let text = item["text"] as! String
                    if var existing = byURL[url] {
                        if existing.text != text { existing.text = text; byURL[url] = existing; modified.append(existing.id) }
                    } else {
                        nextID += 1
                        byURL[url] = Stored(id: nextID, text: text, note: item["note"] as? String ?? "", color: "yellow")
                        modified.append(nextID)
                    }
                }
                return Reply(status: 200, body: #"[{"id":9,"title":"Middlemarch","modified_highlights":\#(modified)}]"#)
            case ("GET", "/api/v2/highlights"):
                let results = byURL.map { #"{"id":\#($0.value.id),"url":"\#($0.key)"}"# }.joined(separator: ",")
                return Reply(status: 200, body: #"{"next":null,"results":[\#(results)]}"#)
            case ("PATCH", _):
                let id = Int(request.url!.lastPathComponent)!
                guard !deletedIDs.contains(id), let url = byURL.first(where: { $0.value.id == id })?.key else {
                    return Reply(status: 404)
                }
                let update = body(request)
                byURL[url]?.text = update["text"] as! String
                byURL[url]?.note = update["note"] as! String
                byURL[url]?.color = update["color"] as! String
                return Reply(status: 200, body: "{}")
            default:
                return Reply(status: 500)
            }
        }
    }
}

@Suite struct ReadwisePushTests {
    private func setUp() async throws -> (AppDatabase, String, FakeReadwise, FakeTransport, ReadwiseClient) {
        let (db, book) = try await seededDatabase()
        let readwise = FakeReadwise()
        let transport = FakeTransport { request, _ in readwise.handle(request) }
        let client = ReadwiseClient(token: "t", transport: transport, sleep: { _ in })
        return (db, book, readwise, transport, client)
    }

    @Test func firstPushCreatesResolvesIdsAndMarks() async throws {
        let (db, book, readwise, transport, client) = try await setUp()
        let a = try await save(db, book: book, quote: "alpha", offset: 1)
        let b = try await save(db, book: book, quote: "beta", offset: 2)
        _ = try await db.addTag(name: "Big Idea", toHighlight: a.id, now: at(3))

        let pusher = ReadwisePusher(database: db)
        let result = try await pusher.push(client: client, now: at(10))
        #expect(result == ReadwisePushResult(created: 2, updated: 0, rejected: 0))
        #expect(await transport.summary() == ["POST /api/v2/highlights", "GET /api/v2/highlights"])
        #expect(postedURLs(await transport.requests[0]) == ["margins://highlight/\(a.id)", "margins://highlight/\(b.id)"])
        #expect(readwise.stored(a.id)?.note == ".Big-Idea")
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
        let ids = try await db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM readwise_highlight") }
        #expect(ids == 2)
    }

    @Test func secondPushSendsNothing() async throws {
        let (db, book, _, transport, client) = try await setUp()
        _ = try await save(db, book: book, offset: 1)
        let pusher = ReadwisePusher(database: db)
        _ = try await pusher.push(client: client, now: at(10))
        let before = await transport.requests.count
        #expect(try await pusher.push(client: client, now: at(20)) == ReadwisePushResult())
        #expect(await transport.requests.count == before)
    }

    @Test func editedNoteIsPatched() async throws {
        let (db, book, readwise, transport, client) = try await setUp()
        let highlight = try await save(db, book: book, quote: "alpha", offset: 1)
        let pusher = ReadwisePusher(database: db)
        _ = try await pusher.push(client: client, now: at(10))
        try await db.updateHighlight(id: highlight.id, color: .pink, note: "second thoughts", now: at(11))

        let result = try await pusher.push(client: client, now: at(20))
        #expect(result == ReadwisePushResult(created: 0, updated: 1, rejected: 0))
        #expect(await transport.summary().last == "PATCH /api/v2/highlights/\(readwise.stored(highlight.id)!.id)")
        #expect(readwise.stored(highlight.id)?.note == "second thoughts")
        #expect(readwise.stored(highlight.id)?.color == "pink")
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
    }

    @Test func pushedBeforeWithoutIdIsRepostedThenPatched() async throws {
        let (db, book, readwise, transport, client) = try await setUp()
        let highlight = try await save(db, book: book, quote: "alpha", offset: 1)
        let pusher = ReadwisePusher(database: db)
        _ = try await pusher.push(client: client, now: at(10))
        try await db.clearReadwiseID(highlightID: highlight.id) // e.g. a new device after sync
        try await db.updateHighlight(id: highlight.id, note: "new note", now: at(11))

        _ = try await pusher.push(client: client, now: at(20))
        #expect(Array(await transport.summary().suffix(3)) == [
            "POST /api/v2/highlights", "GET /api/v2/highlights",
            "PATCH /api/v2/highlights/\(readwise.stored(highlight.id)!.id)",
        ])
        #expect(readwise.stored(highlight.id)?.note == "new note")
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
    }

    @Test func rejectedHighlightDoesNotBlockTheBatch() async throws {
        let (db, book, readwise, _, client) = try await setUp()
        for index in 0 ..< 5 {
            _ = try await save(db, book: book, quote: "quote \(index)", offset: Double(index + 1))
        }
        readwise.rejectText = "quote 3"
        let result = try await ReadwisePusher(database: db).push(client: client, now: at(10))
        #expect(result == ReadwisePushResult(created: 4, updated: 0, rejected: 1))
        #expect(try await db.pendingReadwiseHighlights().map(\.quote) == ["quote 3"])
    }

    @Test func deletedInReadwiseIsRecreated() async throws {
        let (db, book, readwise, _, client) = try await setUp()
        let highlight = try await save(db, book: book, quote: "alpha", offset: 1)
        let pusher = ReadwisePusher(database: db)
        _ = try await pusher.push(client: client, now: at(10))
        readwise.deletedIDs.insert(readwise.stored(highlight.id)!.id)
        try await db.updateHighlight(id: highlight.id, note: "edit", now: at(11))

        let result = try await pusher.push(client: client, now: at(20))
        #expect(result == ReadwisePushResult(created: 1, updated: 0, rejected: 0))
        #expect(try await db.pendingReadwiseHighlights().isEmpty)
    }

    @Test func unauthorizedStopsAndLeavesPending() async throws {
        let (db, book) = try await seededDatabase()
        _ = try await save(db, book: book, offset: 1)
        let client = ReadwiseClient(token: "bad", transport: FakeTransport { _, _ in Reply(status: 401) })
        await #expect(throws: ReadwiseError.unauthorized) {
            try await ReadwisePusher(database: db).push(client: client, now: at(10))
        }
        #expect(try await db.pendingReadwiseHighlights().count == 1)
    }

    @Test func batchesOfOneHundred() async throws {
        let (db, book, _, transport, client) = try await setUp()
        for index in 0 ..< 150 {
            _ = try await save(db, book: book, quote: "q\(index)", offset: Double(index))
        }
        _ = try await ReadwisePusher(database: db).push(client: client, now: at(1000))
        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.map { postedURLs($0).count } == [100, 50])
    }
}
