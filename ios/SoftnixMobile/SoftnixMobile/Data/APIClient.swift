import Foundation

enum AppError: LocalizedError, Sendable, Equatable {
    case invalidServerURL, invalidPairingCode, invalidResponse, attachmentTooLarge, noSpeech
    case server(String), revoked(String), transcription(String, String?), keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid HTTP or HTTPS Softnix server URL."
        case .invalidPairingCode: "The QR code is not a valid Softnix mobile pairing code."
        case .invalidResponse: "The server returned an unsupported response."
        case .attachmentTooLarge: "Each attachment must be 15 MB or smaller."
        case .noSpeech: "No speech was detected."
        case .server(let message), .revoked(let message): message
        case .transcription(let message, let code):
            code == "groq_key_missing"
            ? "Voice transcription is not configured for this Softnix instance. Ask an admin to set the Groq API key in Providers, then try recording again."
            : message
        case .keychain: "Unable to securely save this session."
        }
    }
}

actor APIClient {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .default) {
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 35
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func authOptions(baseURL: URL) async throws -> AuthOptions {
        try await request(baseURL: baseURL, path: "/admin/web-chat/auth/options")
    }
    func passwordLogin(baseURL: URL, login: String, password: String) async throws -> PasswordLoginResponse {
        try await request(baseURL: baseURL, path: "/admin/web-chat/auth/password", method: "POST",
                          body: ["login": login, "password": password])
    }
    func instances(baseURL: URL) async throws -> PasswordLoginResponse {
        try await request(baseURL: baseURL, path: "/admin/web-chat/auth/instances")
    }
    func selectInstance(baseURL: URL, instanceID: String) async throws -> BootstrapResponse {
        _ = try await data(baseURL: baseURL, path: "/admin/web-chat/auth/select-instance", method: "POST",
                           body: ["instance_id": instanceID])
        return try await request(baseURL: baseURL, path: "/admin/web-chat/bootstrap")
    }
    func register(payload: PairingPayload, deviceID: String, label: String) async throws -> MobileCredential {
        let response: MobileRegistrationResponse = try await request(
            baseURL: payload.apiBaseURL, path: "/admin/mobile/register", method: "POST",
            body: [
                "instance_id": payload.instanceID, "device_id": deviceID,
                "pairing_token": payload.token, "label": label, "platform": "ios",
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            ])
        return MobileCredential(apiBaseURL: payload.apiBaseURL, instanceID: payload.instanceID,
                                deviceID: deviceID, deviceToken: response.deviceToken, label: label)
    }

    func bootstrap(credential: AppCredential, activeSessionID: String?) async throws -> BootstrapResponse {
        switch credential {
        case .mobile(let c):
            var query = mobileQuery(c)
            if let activeSessionID { query.append(URLQueryItem(name: "active_session_id", value: activeSessionID)) }
            return try await request(baseURL: c.apiBaseURL, path: "/admin/mobile/bootstrap",
                                     query: query, headers: mobileHeaders(c))
        case .web(let c):
            return try await request(baseURL: c.apiBaseURL, path: "/admin/web-chat/bootstrap")
        }
    }

    func events(credential: AppCredential, after: String?) async throws -> EventsResponse {
        switch credential {
        case .mobile(let c):
            var query = mobileQuery(c)
            if let after { query.append(URLQueryItem(name: "after_event_id", value: after)) }
            return try await request(baseURL: c.apiBaseURL, path: "/admin/mobile/events",
                                     query: query, headers: mobileHeaders(c))
        case .web(let c):
            let query = after.map { [URLQueryItem(name: "after_event_id", value: $0)] } ?? []
            return try await request(baseURL: c.apiBaseURL, path: "/admin/web-chat/events", query: query)
        }
    }

    func eventStream(credential: AppCredential, after: String?) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        guard case .mobile(let c) = credential else {
            throw AppError.server("Native SSE requires a paired mobile device.")
        }
        var query = mobileQuery(c)
        query.append(URLQueryItem(name: "mobile_token", value: c.deviceToken))
        if let after { query.append(URLQueryItem(name: "after_event_id", value: after)) }
        var request = try makeRequest(baseURL: c.apiBaseURL, path: "/admin/mobile/events/stream",
                                      query: query, headers: ["Accept": "text/event-stream"])
        if let after { request.setValue(after, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response: response, data: Data())
        return AsyncThrowingStream { continuation in
            let task = Task {
                var dataLines: [String] = []
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                if let data = payload.data(using: .utf8),
                                   let event = try? self.decoder.decode(ChatEvent.self, from: data) {
                                    continuation.yield(event)
                                }
                                dataLines.removeAll()
                            }
                        } else if line.hasPrefix("data:") {
                            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
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

    func send(credential: AppCredential, text: String, messageID: String, sessionID: String,
              replyTo: String?, threadRootID: String?, attachments: [OutgoingAttachment]) async throws -> MessageResponse {
        var payload: [String: Any] = [
            "text": text, "message_id": messageID, "session_id": sessionID,
            "attachments": try attachments.map { try dictionary($0) }, "metadata": [String: Any](),
        ]
        payload["reply_to"] = replyTo ?? NSNull()
        payload["thread_root_id"] = threadRootID ?? NSNull()
        switch credential {
        case .mobile(let c):
            payload["instance_id"] = c.instanceID; payload["sender_id"] = c.deviceID
            return try await request(baseURL: c.apiBaseURL, path: "/admin/mobile/message", method: "POST",
                                     body: payload, headers: mobileHeaders(c))
        case .web(let c):
            return try await request(baseURL: c.apiBaseURL, path: "/admin/web-chat/message", method: "POST",
                                     body: payload, headers: ["X-CSRF-Token": c.csrfToken])
        }
    }

    func transcribe(credential: AppCredential, audio: OutgoingAttachment) async throws -> TranscriptionResponse {
        guard case .mobile(let c) = credential else { throw AppError.server("Voice transcription requires device pairing.") }
        do {
            return try await request(baseURL: c.apiBaseURL, path: "/admin/mobile/transcribe", method: "POST",
                                     body: ["instance_id": c.instanceID, "sender_id": c.deviceID,
                                            "audio": try dictionary(audio)], headers: mobileHeaders(c))
        } catch AppError.server(let message) {
            throw AppError.transcription(message, nil)
        }
    }

    func decideWorkflow(credential: AppCredential, card: WorkflowCard, decision: String, sessionID: String) async throws {
        guard case .mobile(let c) = credential else { throw AppError.server("Workflow approval requires device pairing.") }
        let path: String
        if card.type == "workflow_preflight", let id = card.intentID {
            path = "/admin/mobile/workflow-intents/\(id)/\(decision)"
        } else if let id = card.runID {
            path = "/admin/mobile/workflows/\(id)/\(decision)"
        } else { throw AppError.invalidResponse }
        _ = try await data(baseURL: c.apiBaseURL, path: path, method: "POST",
                           body: ["instance_id": c.instanceID, "sender_id": c.deviceID, "session_id": sessionID],
                           headers: mobileHeaders(c))
    }

    func subscribePush(credential: AppCredential, token: String) async throws {
        guard case .mobile(let c) = credential else { return }
        _ = try await data(baseURL: c.apiBaseURL, path: "/admin/mobile/push/subscribe", method: "POST",
                           body: ["instance_id": c.instanceID, "device_id": c.deviceID,
                                  "push_token": token, "push_provider": "apns"], headers: mobileHeaders(c))
    }
    func unsubscribePush(credential: AppCredential) async throws {
        guard case .mobile(let c) = credential else { return }
        _ = try await data(baseURL: c.apiBaseURL, path: "/admin/mobile/push/unsubscribe", method: "POST",
                           body: ["instance_id": c.instanceID, "device_id": c.deviceID], headers: mobileHeaders(c))
    }

    func download(credential: AppCredential, attachment: Attachment) async throws -> URL {
        guard case .mobile(let c) = credential else { throw AppError.server("Media download requires device pairing.") }
        let request: URLRequest
        if let fileName = attachment.fileName ?? attachment.name.nilIfEmpty, let sender = attachment.senderID {
            request = try makeRequest(baseURL: c.apiBaseURL, path: "/admin/mobile/media",
                                      query: [URLQueryItem(name: "instance_id", value: c.instanceID),
                                              URLQueryItem(name: "sender_id", value: sender),
                                              URLQueryItem(name: "file", value: fileName)],
                                      headers: mobileHeaders(c))
        } else if let raw = attachment.url, let url = URL(string: raw, relativeTo: c.apiBaseURL) {
            var value = URLRequest(url: url); value.setValue(c.deviceToken, forHTTPHeaderField: "X-Mobile-Token")
            request = value
        } else { throw AppError.invalidResponse }
        let (temporary, response) = try await session.download(for: request)
        try validate(response: response, data: Data())
        guard let http = response as? HTTPURLResponse,
              let mime = http.mimeType, mime != "text/html", mime != "application/json" else {
            throw AppError.invalidResponse
        }
        let pathExtension = ((attachment.fileName ?? attachment.name) as NSString).pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension(pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func request<T: Decodable & Sendable>(baseURL: URL, path: String, method: String = "GET",
                                                   query: [URLQueryItem] = [], body: Any? = nil,
                                                   headers: [String: String] = [:]) async throws -> T {
        let value = try await data(baseURL: baseURL, path: path, method: method, query: query, body: body, headers: headers)
        do { return try decoder.decode(T.self, from: value) }
        catch { throw AppError.invalidResponse }
    }

    private func data(baseURL: URL, path: String, method: String = "GET", query: [URLQueryItem] = [],
                      body: Any? = nil, headers: [String: String] = [:]) async throws -> Data {
        var request = try makeRequest(baseURL: baseURL, path: path, method: method, query: query, headers: headers)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    private func makeRequest(baseURL: URL, path: String, method: String = "GET",
                             query: [URLQueryItem] = [], headers: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                                             resolvingAgainstBaseURL: false) else { throw AppError.invalidServerURL }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AppError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let payload = try? decoder.decode(ServerErrorPayload.self, from: data)
        let message = payload?.error ?? "Request failed (\(http.statusCode))"
        if http.statusCode == 401 || http.statusCode == 403 { throw AppError.revoked(message) }
        if payload?.errorCode != nil { throw AppError.transcription(message, payload?.errorCode) }
        throw AppError.server(message)
    }

    private func mobileHeaders(_ c: MobileCredential) -> [String: String] { ["X-Mobile-Token": c.deviceToken] }
    private func mobileQuery(_ c: MobileCredential) -> [URLQueryItem] {
        [URLQueryItem(name: "instance_id", value: c.instanceID), URLQueryItem(name: "sender_id", value: c.deviceID)]
    }
    private func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }
}
