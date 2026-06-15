import Foundation
import Network
import UIKit
import UserNotifications

struct PairingHandler {
    let api: APIClient
    func pair(rawValue: String, deviceID: String, label: String) async throws -> AppCredential {
        let payload = try PairingParser.parse(rawValue)
        return .mobile(try await api.register(payload: payload, deviceID: deviceID, label: label))
    }
}

struct AuthenticationInterceptor {
    let onRevoked: @MainActor @Sendable () -> Void
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch let error as AppError {
            if case .revoked = error { await onRevoked() }
            throw error
        }
    }
}

struct ChatBootstrapHandler {
    let api: APIClient
    func load(credential: AppCredential, activeSessionID: String?) async throws -> BootstrapResponse {
        try await api.bootstrap(credential: credential, activeSessionID: activeSessionID)
    }
}

actor ChatEventStreamHandler {
    private let api: APIClient
    private var task: Task<Void, Never>?
    init(api: APIClient) { self.api = api }

    func start(credential: AppCredential, cursor: @escaping @MainActor @Sendable () -> String?,
               receive: @escaping @MainActor @Sendable (ChatEvent) -> Void,
               failure: @escaping @MainActor @Sendable (Error) -> Void) {
        task?.cancel()
        task = Task {
            var backoff = ReconnectBackoff()
            while !Task.isCancelled {
                do {
                    let stream = try await api.eventStream(credential: credential, after: await cursor())
                    for try await event in stream {
                        await receive(event)
                        backoff.reset()
                    }
                } catch is CancellationError { return }
                catch {
                    await failure(error)
                    do { try await Task.sleep(for: .seconds(backoff.nextDelay())) } catch { return }
                }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct ReconnectBackoff: Sendable {
    private(set) var current: Double = 1
    mutating func nextDelay() -> Double {
        let value = current
        current = min(current * 2, 30)
        return value
    }
    mutating func reset() { current = 1 }
}

actor PollingFallbackHandler {
    private let api: APIClient
    private var task: Task<Void, Never>?
    init(api: APIClient) { self.api = api }
    func start(credential: AppCredential, cursor: @escaping @MainActor @Sendable () -> String?,
               receive: @escaping @MainActor @Sendable ([ChatEvent]) -> Void,
               failure: @escaping @MainActor @Sendable (Error) -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                do { await receive(try await api.events(credential: credential, after: await cursor()).events) }
                catch is CancellationError { return }
                catch { await failure(error) }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

struct MessageSendHandler {
    let api: APIClient
    func send(credential: AppCredential, message: ChatMessage, attachments: [OutgoingAttachment]) async throws {
        try await withTimeout(seconds: attachments.isEmpty ? 45 : 90) {
            _ = try await api.send(credential: credential, text: message.text, messageID: message.id,
                                   sessionID: message.sessionID, replyTo: message.replyTo,
                                   threadRootID: message.threadRootID, attachments: attachments)
        }
    }

    private func withTimeout(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppError.requestTimedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

struct AttachmentUploadHandler {
    static let maximumBytes = 15 * 1024 * 1024
    func prepare(_ pending: [PendingAttachment], progress: @MainActor @Sendable (UUID, Double) -> Void) async throws -> [OutgoingAttachment] {
        var output: [OutgoingAttachment] = []
        for item in pending {
            guard item.size <= Self.maximumBytes else { throw AppError.attachmentTooLarge }
            await progress(item.id, 0.15)
            let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
            try Task.checkCancellation()
            await progress(item.id, 0.7)
            output.append(OutgoingAttachment(name: item.name, type: item.mimeType,
                                             size: data.count, dataBase64: data.base64EncodedString()))
            await progress(item.id, 1)
        }
        return output
    }
}

struct MediaDownloadHandler {
    let api: APIClient
    func download(credential: AppCredential, attachment: Attachment) async throws -> URL {
        try await api.download(credential: credential, attachment: attachment)
    }
}

struct TranscriptionHandler {
    let api: APIClient
    func transcribe(credential: AppCredential, fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw AppError.noSpeech }
        let response = try await api.transcribe(
            credential: credential,
            audio: OutgoingAttachment(name: "voice-\(UUID().uuidString.lowercased()).m4a",
                                      type: "audio/m4a", size: data.count,
                                      dataBase64: data.base64EncodedString())
        )
        let transcript = response.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw AppError.noSpeech }
        return transcript
    }
}

struct WorkflowCardHandler {
    let api: APIClient
    let persistence: ChatPersistence
    func decide(credential: AppCredential, card: WorkflowCard, decision: String, sessionID: String) async throws {
        try await api.decideWorkflow(credential: credential, card: card, decision: decision, sessionID: sessionID)
        try await persistence.saveWorkflowDecision(cardID: card.id, decision: decision)
    }
}

struct PushNotificationHandler {
    let api: APIClient
    func requestAuthorization() async throws {
        guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) else {
            throw AppError.server("Notification permission was denied.")
        }
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }
    func subscribe(credential: AppCredential, token: String) async throws {
        try await api.subscribePush(credential: credential, token: token)
    }
    func unsubscribe(credential: AppCredential) async throws { try await api.unsubscribePush(credential: credential) }
    func sessionID(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["session_id"] as? String
            ?? (userInfo["data"] as? [String: Any])?["session_id"] as? String
    }
}

struct AppLifecycleSyncHandler {
    let sync: @MainActor @Sendable () async -> Void
    func becameActive() async { await sync() }
}

final class NetworkRecoveryHandler: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.softnix.mobile.network")
    private let state = NetworkRecoveryState()
    func start(onRecovery: @escaping @MainActor @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [state] path in
            if path.status == .satisfied {
                if state.takeRecovery() { Task { @MainActor in onRecovery() } }
            } else { state.markOffline() }
        }
        monitor.start(queue: queue)
    }
    func stop() { monitor.cancel() }
}

typealias ChatEventReducerHandler = ChatEventReducer

private final class NetworkRecoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var offline = false
    func markOffline() { lock.lock(); offline = true; lock.unlock() }
    func takeRecovery() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = offline; offline = false; return value
    }
}
