import Foundation

enum EngineClientError: LocalizedError {
    case invalidResponse
    case api(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The engine returned an invalid response."
        case .api(let message):
            return message
        case .offline:
            return "The engine is not running."
        }
    }
}

/// Thin typed client for the loopback engine API.
struct EngineClient {
    let baseURL: URL
    let token: String
    private let session: URLSession

    init(port: Int, token: String) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token

        let configuration = URLSessionConfiguration.ephemeral
        // Docker pulls and compose up can legitimately take minutes.
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 1800
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - JSON

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(method: "GET", path: path, query: query, body: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await perform(method: "POST", path: path, query: [], body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func postVoid(_ path: String, body: (any Encodable)? = nil) async throws {
        _ = try await perform(method: "POST", path: path, query: [], body: body)
    }

    func patch<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await perform(method: "PATCH", path: path, query: [], body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func delete<T: Decodable>(_ path: String) async throws -> T {
        let data = try await perform(method: "DELETE", path: path, query: [], body: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func deleteVoid(_ path: String) async throws {
        _ = try await perform(method: "DELETE", path: path, query: [], body: nil)
    }

    // MARK: - Streaming

    func stream(_ path: String, query: [URLQueryItem] = []) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(method: "GET", path: path, query: query, body: nil)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw EngineClientError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var raw = ""
                        for try await byte in bytes {
                            raw.append(Character(UnicodeScalar(byte)))
                            if raw.count > 4096 { break }
                        }
                        throw EngineClientError.api(raw.isEmpty ? "HTTP \(http.statusCode)" : raw)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line == "event: end" { break }
                        if line.hasPrefix("data:") {
                            var payload = Substring(line.dropFirst(5))
                            if payload.hasPrefix(" ") { payload = payload.dropFirst() }
                            continuation.yield(String(payload))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func perform(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: (any Encodable)?
    ) async throws -> Data {
        let request = try makeRequest(method: method, path: path, query: query, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw EngineClientError.api(message)
        }
        return data
    }

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: (any Encodable)?
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw EngineClientError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(AnyEncodable(body))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

/// Type-erasing wrapper so `post` can accept any Encodable payload.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeClosure = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}

extension String {
    /// Percent-encodes a value so it is safe to place inside an API path.
    var pathComponentEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
