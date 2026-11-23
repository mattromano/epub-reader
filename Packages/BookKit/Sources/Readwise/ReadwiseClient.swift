import Foundation

/// Sends one HTTP request. `URLSession` in the app, a fake in tests.
public protocol ReadwiseTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: ReadwiseTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReadwiseError.badResponse }
        return (data, http)
    }
}

/// Descriptions never include the request, its headers or the token.
public enum ReadwiseError: Error, Equatable, LocalizedError {
    case unauthorized
    /// 429 with a `Retry-After` (seconds) longer than the caller can wait, or retries ran out.
    case rateLimited(retryAfter: Double)
    case notFound
    /// Any other 4xx: Readwise rejected the request body.
    case rejected(status: Int)
    case server(status: Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Readwise didn't accept the token."
        case let .rateLimited(seconds): "Readwise asked to wait \(Int(seconds.rounded())) s. Try again later."
        case .notFound: "Readwise couldn't find that highlight."
        case let .rejected(status): "Readwise rejected the request (HTTP \(status))."
        case let .server(status): "Readwise had a problem (HTTP \(status)). Try again later."
        case .badResponse: "Readwise sent a response Margins couldn't read."
        }
    }
}

/// The Readwise v2 endpoints M7 uses ([api_deets](https://readwise.io/api_deets)).
public struct ReadwiseClient: Sendable {
    public static let baseURL = URL(string: "https://readwise.io/api/v2/")!

    private let token: String
    private let transport: any ReadwiseTransport
    private let sleep: @Sendable (Double) async throws -> Void
    /// The longest `Retry-After` worth sleeping through; longer throws `.rateLimited`.
    private let maxRetryWait: Double
    private let maxRetries: Int

    public init(token: String, transport: any ReadwiseTransport = URLSessionTransport(),
                maxRetryWait: Double = 60, maxRetries: Int = 3,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.token = token
        self.transport = transport
        self.maxRetryWait = maxRetryWait
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    /// `GET /auth/`: true on 204, false when the token is refused.
    public func validateToken() async throws -> Bool {
        do {
            let (_, status) = try await perform(request("auth/", method: "GET"))
            return status == 204
        } catch ReadwiseError.unauthorized {
            return false
        }
    }

    /// `POST /highlights/`. Returns the books the highlights were filed under.
    public func createHighlights(_ highlights: [ReadwiseCreateHighlight]) async throws -> [ReadwiseBook] {
        var request = request("highlights/", method: "POST")
        request.httpBody = try JSONEncoder().encode(["highlights": highlights])
        let (data, _) = try await perform(request)
        // The body must be a JSON array of books; anything else (e.g. a redirect that turned into
        // a GET returning a list page) is not a successful create, so nothing gets marked sent.
        guard let books = try? JSONDecoder().decode([ReadwiseBook].self, from: data) else {
            throw ReadwiseError.badResponse
        }
        return books
    }

    /// `PATCH /highlights/<id>/`.
    public func updateHighlight(id: Int, _ update: ReadwiseUpdateHighlight) async throws {
        var request = request("highlights/\(id)/", method: "PATCH")
        request.httpBody = try JSONEncoder().encode(update)
        _ = try await perform(request)
    }

    /// Every highlight in a Readwise book (`GET /highlights/?book_id=`), following `next`.
    public func highlights(bookID: Int) async throws -> [ReadwiseListedHighlight] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("highlights/"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "book_id", value: String(bookID)),
                                 URLQueryItem(name: "page_size", value: "1000")]
        var next = components.url
        var results: [ReadwiseListedHighlight] = []
        while let url = next {
            // Only follow pages on Readwise's own host, so the token never goes elsewhere.
            guard url.host == Self.baseURL.host, url.scheme == "https" else { throw ReadwiseError.badResponse }
            let (data, _) = try await perform(request(url: url, method: "GET"))
            guard let page = try? JSONDecoder().decode(ReadwiseHighlightPage.self, from: data) else {
                throw ReadwiseError.badResponse
            }
            results += page.results
            next = page.next.flatMap(URL.init(string:))
        }
        return results
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String) -> URLRequest {
        request(url: Self.baseURL.appendingPathComponent(path), method: method)
    }

    private func request(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        return request
    }

    /// Sends, sleeping through 429s whose `Retry-After` is short enough. Returns body and status.
    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            let (data, response) = try await transport.send(request)
            let status = response.statusCode
            switch status {
            case 200 ..< 300:
                return (data, status)
            case 401, 403:
                throw ReadwiseError.unauthorized
            case 404:
                throw ReadwiseError.notFound
            case 429:
                let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
                guard attempt < maxRetries, wait <= maxRetryWait else {
                    throw ReadwiseError.rateLimited(retryAfter: wait)
                }
                attempt += 1
                try await sleep(wait)
            case 400 ..< 500:
                throw ReadwiseError.rejected(status: status)
            default:
                throw ReadwiseError.server(status: status)
            }
        }
    }
}
