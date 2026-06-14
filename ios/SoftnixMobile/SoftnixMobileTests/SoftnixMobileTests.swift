import XCTest
@testable import SoftnixMobile

final class SoftnixMobileTests: XCTestCase {
    func testEventAndMessageDeduplicationWithCursorReplay() throws {
        var reducer = ChatEventReducer()
        var state = ChatState()
        let first = try event(id: "evt-1", message: "msg-1", text: "first")
        reducer.reduce(state: &state, event: first, fallbackDeviceID: "mob-1")
        reducer.reduce(state: &state, event: first, fallbackDeviceID: "mob-1")
        reducer.reduce(state: &state, event: try event(id: "evt-2", message: "msg-1", text: "updated"),
                       fallbackDeviceID: "mob-1")
        XCTAssertEqual(state.conversations[0].messages.count, 1)
        XCTAssertEqual(state.conversations[0].messages[0].text, "updated")
        XCTAssertEqual(state.lastEventID, "evt-2")
    }

    func testOutOfOrderEventsSortByTimestampThenMessageID() throws {
        var reducer = ChatEventReducer()
        var state = ChatState()
        reducer.reduce(state: &state, event: try event(id: "2", message: "b", text: "later",
                                                       timestamp: "2026-01-01T00:00:02Z"), fallbackDeviceID: "mob")
        reducer.reduce(state: &state, event: try event(id: "1", message: "a", text: "earlier",
                                                       timestamp: "2026-01-01T00:00:01Z"), fallbackDeviceID: "mob")
        XCTAssertEqual(state.conversations[0].messages.map(\.id), ["a", "b"])
    }

    func testMultipleSessionsAndPreferredSession() throws {
        var reducer = ChatEventReducer()
        var state = ChatState()
        reducer.reduce(state: &state, event: try event(id: "1", message: "1", session: "session-a"),
                       fallbackDeviceID: "mob", activeSessionID: "session-a")
        reducer.reduce(state: &state, event: try event(id: "2", message: "2", session: "session-b"),
                       fallbackDeviceID: "mob", activeSessionID: "session-a")
        XCTAssertEqual(state.conversations.count, 2)
        XCTAssertEqual(state.activeSessionID, "session-a")
    }

    func testProgressToolAnswerGrouping() throws {
        var reducer = ChatEventReducer()
        var state = ChatState()
        reducer.reduce(state: &state, event: try event(id: "1", message: "p", type: "progress",
                                                       timestamp: "2026-01-01T00:00:01Z"), fallbackDeviceID: "mob")
        reducer.reduce(state: &state, event: try event(id: "2", message: "t", type: "tool",
                                                       timestamp: "2026-01-01T00:00:02Z"), fallbackDeviceID: "mob")
        reducer.reduce(state: &state, event: try event(id: "3", message: "a", type: "answer",
                                                       timestamp: "2026-01-01T00:00:03Z"), fallbackDeviceID: "mob")
        let timeline = reducer.timeline(for: state.conversations[0])
        XCTAssertEqual(timeline.count, 2)
        if case .processing(let group) = timeline[0] { XCTAssertEqual(group.steps.count, 2) }
        else { XCTFail("Expected processing group") }
    }

    func testOptimisticRollbackAndRetryUsesSameMessageID() throws {
        var reducer = ChatEventReducer()
        var state = ChatState()
        reducer.reduceOptimistic(state: &state, event: .optimistic(
            messageID: "mobu-fixed", sessionID: "s", text: "hello", replyTo: nil, threadRootID: nil
        ), fallbackDeviceID: "mob")
        reducer.setDelivery(state: &state, messageID: "mobu-fixed", delivery: .failed, error: "offline")
        XCTAssertEqual(state.conversations[0].messages[0].id, "mobu-fixed")
        XCTAssertEqual(state.conversations[0].messages[0].deliveryState, .failed)
        reducer.setDelivery(state: &state, messageID: "mobu-fixed", delivery: .sending)
        XCTAssertEqual(state.conversations[0].messages[0].id, "mobu-fixed")
    }

    func testAttachmentSizeRejection() async {
        let item = PendingAttachment(id: UUID(), url: URL(fileURLWithPath: "/tmp/missing"),
                                     name: "large", mimeType: "application/octet-stream",
                                     size: AttachmentUploadHandler.maximumBytes + 1, progress: 0)
        do {
            _ = try await AttachmentUploadHandler().prepare([item]) { _, _ in }
            XCTFail("Expected size rejection")
        } catch {
            XCTAssertEqual(error as? AppError, .attachmentTooLarge)
        }
    }

    func testWorkflowCardDecodeAndDecisionIdentity() throws {
        let data = Data(#"{"type":"workflow_approval","run_id":"wf_abc","risk_level":"high","required_tools":["shell"]}"#.utf8)
        let card = try JSONDecoder().decode(WorkflowCard.self, from: data)
        XCTAssertEqual(card.id, "wf_abc")
        XCTAssertEqual(card.riskLevel, "high")
        XCTAssertEqual(card.requiredTools, ["shell"])
    }

    func testVoiceTranscriptionErrorCode() {
        let error = AppError.transcription("missing", "groq_key_missing")
        XCTAssertTrue(error.localizedDescription.contains("not configured"))
    }

    func testRevokedDeviceTokenClassification() {
        XCTAssertEqual(AppError.revoked("Invalid mobile device token").localizedDescription,
                       "Invalid mobile device token")
    }

    func testPushDeepLink() {
        let handler = PushNotificationHandler(api: APIClient())
        XCTAssertEqual(handler.sessionID(from: ["session_id": "mobile-mob-1-thread"]), "mobile-mob-1-thread")
        XCTAssertEqual(handler.sessionID(from: ["data": ["session_id": "nested"]]), "nested")
    }

    func testReconnectAfterSSEExpirationUsesCappedExponentialBackoff() {
        var backoff = ReconnectBackoff()
        XCTAssertEqual((0..<7).map { _ in backoff.nextDelay() }, [1, 2, 4, 8, 16, 30, 30])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }

    func testPollingFallbackAndDownloadAuthentication() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(configuration: configuration)
        let credential = AppCredential.mobile(MobileCredential(
            apiBaseURL: URL(string: "https://example.invalid")!, instanceID: "prod",
            deviceID: "mob-1", deviceToken: "secret-token", label: "Test"
        ))
        var receivedToken: String?
        MockURLProtocol.handler = { request in
            receivedToken = request.value(forHTTPHeaderField: "X-Mobile-Token")
            if request.url?.path == "/admin/mobile/events" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": "application/json"])!,
                        Data(#"{"events":[]}"#.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "image/png"])!, Data([0x89, 0x50, 0x4E, 0x47]))
        }
        _ = try await api.events(credential: credential, after: "evt-1")
        XCTAssertEqual(receivedToken, "secret-token")
        let file = try await api.download(
            credential: credential,
            attachment: Attachment(name: "image.png", fileName: "image.png", mimeType: "image/png",
                                   size: 4, senderID: "mob-1")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(receivedToken, "secret-token")
        try? FileManager.default.removeItem(at: file)
    }

    func testTranscriptionServerErrorCode() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let api = APIClient(configuration: configuration)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
                             headerFields: ["Content-Type": "application/json"])!,
             Data(#"{"error":"Groq API key is not configured for transcription","error_code":"groq_key_missing"}"#.utf8))
        }
        let credential = AppCredential.mobile(MobileCredential(
            apiBaseURL: URL(string: "https://example.invalid")!, instanceID: "prod",
            deviceID: "mob-1", deviceToken: "secret", label: "Test"
        ))
        do {
            _ = try await api.transcribe(
                credential: credential,
                audio: OutgoingAttachment(name: "voice.m4a", type: "audio/m4a", size: 1, dataBase64: "AA==")
            )
            XCTFail("Expected transcription failure")
        } catch let error as AppError {
            XCTAssertTrue(error.localizedDescription.contains("not configured"))
        } catch { XCTFail("Unexpected error \(error)") }
    }

    private func event(id: String, message: String, session: String = "session-a", type: String = "answer",
                       text: String = "value", timestamp: String = "2026-01-01T00:00:00Z") throws -> ChatEvent {
        let json: [String: Any] = [
            "event_id": id, "message_id": message, "session_id": session,
            "role": type == "message" ? "user" : "agent", "direction": "outbound",
            "type": type, "text": text, "timestamp": timestamp, "attachments": [],
        ]
        return try JSONDecoder().decode(ChatEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw AppError.invalidResponse }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
