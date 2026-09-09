import Foundation

enum VistaError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int, String)
    case transport(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No Vista server address set. Sign in again to choose one."
        case .unauthorized:
            return "Your session has expired. Sign in again."
        case let .server(_, detail):
            return detail
        case let .transport(detail):
            return detail
        case let .malformedResponse(detail):
            return detail
        }
    }
}

/// Talks to the Vista server. Never sees an Ark token — Vista holds that.
actor VistaClient {
    private var baseURL: URL?
    private var token: String?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func configure(baseURL: URL?, token: String?) {
        self.baseURL = baseURL
        self.token = token
    }

    func setToken(_ token: String?) {
        self.token = token
    }

    // MARK: - Coding

    /// The server emits ISO-8601 both with and without fractional seconds:
    /// brief dates come from a plain date, note timestamps from a float. One
    /// strategy has to accept both or decoding fails at runtime.
    /// `ISO8601DateFormatter` is thread-safe for parsing but predates
    /// `Sendable`, so holding the two instances in a checked-unsafe box keeps
    /// them out of the decoder closure's concurrency diagnostics without
    /// rebuilding a formatter for every date.
    private struct DateParsers: @unchecked Sendable {
        let withFraction: ISO8601DateFormatter
        let plain: ISO8601DateFormatter

        init() {
            withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }

        func parse(_ text: String) -> Date? {
            withFraction.date(from: text) ?? plain.date(from: text)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let parsers = DateParsers()

        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = parsers.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date: \(text)")
            )
        }
        return decoder
    }()

    private static let encoder = JSONEncoder()

    /// Decode, turning Foundation's opaque "the data couldn't be read because
    /// it is missing" into something that names the offending field.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw VistaError.malformedResponse(describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            let parent = path(context)
            return "The server response is missing '\(key.stringValue)'"
                + (parent.isEmpty ? "" : " in '\(parent)'")
                + ". The Vista server may be an older version than this app."
        case let .typeMismatch(_, context):
            return "Unexpected type for '\(path(context))' in the server response."
        case let .valueNotFound(_, context):
            return "Missing value for '\(path(context))' in the server response."
        case let .dataCorrupted(context):
            let where_ = path(context)
            return "Could not read the server response"
                + (where_.isEmpty ? "" : " at '\(where_)'")
                + ": \(context.debugDescription)"
        @unknown default:
            return "Could not read the server response."
        }
    }

    // MARK: - Plumbing

    private func makeRequest(_ path: String, method: String = "GET",
                             query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL else { throw VistaError.notConfigured }
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else { throw VistaError.notConfigured }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw VistaError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VistaError.transport(error.localizedDescription)
        }
        try Self.check(response: response, data: data)
        return data
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        if http.statusCode == 401 { throw VistaError.unauthorized }

        // The server reports failures as {"detail": "..."}; surface that rather
        // than a bare status code.
        var detail = "Request failed (\(http.statusCode))"
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = body["detail"] as? String {
            detail = message
        }
        throw VistaError.server(http.statusCode, detail)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await perform(try makeRequest(path, query: query))
        return try Self.decode(T.self, from: data)
    }

    @discardableResult
    private func send<T: Decodable>(_ path: String, method: String,
                                    body: some Encodable, query: [URLQueryItem] = []) async throws -> T {
        var request = try makeRequest(path, method: method, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        let data = try await perform(request)
        return try Self.decode(T.self, from: data)
    }

    // MARK: - Auth

    /// Signs in and returns the session token together with the user, which
    /// carries the same fields `me()` would — no follow-up request needed.
    func login(baseURL: URL, email: String, password: String) async throws -> (String, User) {
        self.baseURL = baseURL
        self.token = nil
        struct Body: Encodable { let email: String; let password: String }
        let response: LoginResponse = try await send(
            "api/auth/login", method: "POST", body: Body(email: email, password: password)
        )
        self.token = response.token
        return (response.token, response.user)
    }

    func me() async throws -> User { try await get("api/me") }

    // MARK: - Briefs

    func briefs(briefingID: Int, sort: SortOption) async throws -> BriefsResponse {
        try await get("api/briefings/\(briefingID)/briefs", query: [
            .init(name: "sort", value: sort.field.rawValue),
            .init(name: "order", value: sort.order),
        ])
    }

    /// Download a brief's bytes to a file. PDFKit and QuickLook both want a
    /// URL on disk, and a file also survives being handed to the system
    /// Markup editor.
    func downloadBrief(briefingID: Int, path: String, to destination: URL) async throws {
        let request = try makeRequest("api/briefings/\(briefingID)/file",
                                      query: [.init(name: "path", value: path)])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VistaError.transport(error.localizedDescription)
        }
        try Self.check(response: response, data: data)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
    }

    /// Upload marked-up PDF bytes. The server writes them to a sidecar beside
    /// the original, which it never modifies.
    func saveAnnotation(briefingID: Int, originalPath: String, pdf: Data) async throws {
        var request = try makeRequest("api/briefings/\(briefingID)/annotation", method: "PUT",
                                      query: [.init(name: "path", value: originalPath)])
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.httpBody = pdf
        _ = try await perform(request)
    }

    func deleteAnnotation(briefingID: Int, originalPath: String) async throws {
        let request = try makeRequest("api/briefings/\(briefingID)/annotation", method: "DELETE",
                                      query: [.init(name: "path", value: originalPath)])
        _ = try await perform(request)
    }

    // MARK: - Notes

    func notes(sort: SortOption) async throws -> NotesResponse {
        try await get("api/notes", query: [
            .init(name: "sort", value: sort.field.rawValue),
            .init(name: "order", value: sort.order),
            .init(name: "preview", value: "true"),
        ])
    }

    func note(named name: String) async throws -> NoteContent {
        try await get("api/notes/item", query: [.init(name: "name", value: name)])
    }

    func createNote(title: String, content: String) async throws -> CreatedNote {
        struct Body: Encodable { let title: String; let content: String }
        return try await send("api/notes", method: "POST",
                              body: Body(title: title, content: content))
    }

    func saveNote(name: String, content: String) async throws {
        struct Body: Encodable { let content: String }
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await send("api/notes/item", method: "PUT", body: Body(content: content),
                                    query: [.init(name: "name", value: name)])
    }

    func renameNote(name: String, title: String) async throws -> CreatedNote {
        struct Body: Encodable { let title: String }
        return try await send("api/notes/item/rename", method: "POST", body: Body(title: title),
                              query: [.init(name: "name", value: name)])
    }

    func deleteNote(name: String) async throws {
        let request = try makeRequest("api/notes/item", method: "DELETE",
                                      query: [.init(name: "name", value: name)])
        _ = try await perform(request)
    }

    // MARK: - Settings

    func settings() async throws -> Settings { try await get("api/settings") }

    private struct ArkPayload: Encodable {
        let base_url: String
        let agent: String
        let token: String?
    }

    func testArk(baseURL: String, agent: String, token: String?) async throws -> ConnectionResult {
        try await send("api/settings/ark/test", method: "POST",
                       body: ArkPayload(base_url: baseURL, agent: agent,
                                        token: token?.isEmpty == false ? token : nil))
    }

    func saveArk(baseURL: String, agent: String, token: String?) async throws -> ConnectionResult {
        struct Response: Decodable { let connected: Bool; let detail: String }
        let result: Response = try await send(
            "api/settings/ark", method: "PUT",
            body: ArkPayload(base_url: baseURL, agent: agent,
                             token: token?.isEmpty == false ? token : nil)
        )
        return ConnectionResult(connected: result.connected, detail: result.detail)
    }

    func saveNotesDir(_ dir: String) async throws {
        struct Body: Encodable { let notes_dir: String }
        struct Ack: Decodable { let notes_dir: String }
        let _: Ack = try await send("api/settings/notes", method: "PUT", body: Body(notes_dir: dir))
    }

    func browseWorkspace(path: String) async throws -> WorkspaceListing {
        try await get("api/settings/workspace", query: [.init(name: "path", value: path)])
    }

    private struct BriefingPayload: Encodable { let name: String; let path: String }

    func addBriefing(name: String, path: String) async throws -> Briefing {
        try await send("api/briefings", method: "POST",
                       body: BriefingPayload(name: name, path: path))
    }

    func updateBriefing(id: Int, name: String, path: String) async throws -> Briefing {
        try await send("api/briefings/\(id)", method: "PUT",
                       body: BriefingPayload(name: name, path: path))
    }

    func removeBriefing(id: Int) async throws {
        _ = try await perform(try makeRequest("api/briefings/\(id)", method: "DELETE"))
    }

    func reorderBriefings(ids: [Int]) async throws -> [Briefing] {
        struct Body: Encodable { let ids: [Int] }
        struct Response: Decodable { let briefings: [Briefing] }
        let response: Response = try await send("api/briefings/reorder", method: "POST",
                                                body: Body(ids: ids))
        return response.briefings
    }
}
