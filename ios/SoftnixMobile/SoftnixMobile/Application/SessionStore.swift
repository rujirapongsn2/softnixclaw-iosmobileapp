import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class SessionStore {
    private let api: APIClient
    private let persistence: ChatPersistence
    private let stream: ChatEventStreamHandler
    private let polling: PollingFallbackHandler
    private let networkRecovery = NetworkRecoveryHandler()
    private var reducer = ChatEventReducer()
    private var state = ChatState()
    private var restored = false
    private var failedAttachments: [String: [PendingAttachment]] = [:]
    private var awaitingAgentSessionIDs: Set<String> = []

    var credential: AppCredential?
    var isBusy = false
    var isSending = false
    var isConnected = false
    var errorMessage: String?
    var pendingAttachments: [PendingAttachment] = []
    var replyTarget: ChatMessage?
    var workflowDecisions: [String: String] = [:]
    var downloadingAttachmentID: String?
    var downloadedFile: URL?
    let voice = VoiceRecordingHandler()
    let audio = AudioPlaybackController()

    var conversations: [Conversation] { state.conversations }
    var activeSessionID: String {
        get { state.activeSessionID }
        set { state.activeSessionID = newValue; markActiveRead(); persistSoon() }
    }
    var lastEventID: String? { state.lastEventID }
    var activeConversation: Conversation? { conversations.first { $0.id == activeSessionID } }
    var timeline: [TimelineItem] { activeConversation.map { reducer.timeline(for: $0) } ?? [] }
    var isAgentRunning: Bool { activeConversation?.messages.last?.isProcessing == true }
    var isAwaitingAgentResponse: Bool { awaitingAgentSessionIDs.contains(activeSessionID) }

    init() {
        let api = APIClient()
        self.api = api
        self.persistence = (try? ChatPersistence()) ?? (try! ChatPersistence(inMemory: true))
        self.stream = ChatEventStreamHandler(api: api)
        self.polling = PollingFallbackHandler(api: api)
        credential = KeychainStore.load()
        networkRecovery.start { [weak self] in Task { await self?.synchronize() } }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard let credential else { return }
        if let cached = try? await persistence.load(instanceID: credential.instanceID, deviceID: credential.deviceID) {
            state = cached
        }
        workflowDecisions = (try? await persistence.workflowDecisions()) ?? [:]
        await synchronize()
    }

    func pair(rawValue: String) async {
        await perform {
            let handler = PairingHandler(api: api)
            let newCredential = try await handler.pair(
                rawValue: rawValue, deviceID: KeychainStore.persistentDeviceID(), label: UIDevice.current.name
            )
            try KeychainStore.save(newCredential)
            credential = newCredential
            state = ChatState()
            await synchronize()
        }
    }

    func login(baseURL: URL, username: String, password: String) async -> [InstanceChoice] {
        var result: [InstanceChoice] = []
        await perform { result = try await api.passwordLogin(baseURL: baseURL, login: username, password: password).instances }
        return result
    }

    func finishWebLogin(baseURL: URL, instanceID: String) async {
        await perform {
            let bootstrap = try await api.selectInstance(baseURL: baseURL, instanceID: instanceID)
            guard let device = bootstrap.device, let csrf = bootstrap.session?.csrfToken?.nilIfEmpty else {
                throw AppError.invalidResponse
            }
            let value = AppCredential.web(WebCredential(
                apiBaseURL: baseURL, instanceID: device.instanceID, deviceID: device.deviceID,
                csrfToken: csrf, label: device.label ?? device.deviceID
            ))
            try KeychainStore.save(value); credential = value
            apply(bootstrap.events, preferred: bootstrap.session?.activeSessionID ?? bootstrap.activeSessionID)
            startRealtime()
        }
    }

    func finishOAuth(baseURL: URL) async -> [InstanceChoice] {
        var result: [InstanceChoice] = []
        await perform { result = try await api.instances(baseURL: baseURL).instances }
        return result
    }

    func synchronize() async {
        guard let credential else { return }
        do {
            let response = try await AuthenticationInterceptor(onRevoked: { [weak self] in self?.handleRevoked() })
                .run { try await self.api.bootstrap(credential: credential, activeSessionID: self.state.activeSessionID.nilIfEmpty) }
            rebuildFromBootstrap(response, credential: credential)
            isConnected = true
            startRealtime()
        } catch let error as AppError {
            if case .revoked = error { return }
            isConnected = false
            errorMessage = error.localizedDescription
            NSLog("Softnix bootstrap failed: %@", error.localizedDescription)
        } catch {
            isConnected = false
            NSLog("Softnix bootstrap failed: %@", error.localizedDescription)
        }
    }

    func newConversation() {
        guard let credential else { return }
        let id = "mobile-\(credential.deviceID)-\(UUID().uuidString.lowercased())"
        state.activeSessionID = id
        if !state.conversations.contains(where: { $0.id == id }) {
            state.conversations.insert(Conversation(id: id, messages: []), at: 0)
        }
        replyTarget = nil; persistSoon()
    }

    func send(_ text: String) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!clean.isEmpty || !pendingAttachments.isEmpty), let credential, !isSending else { return false }
        if state.activeSessionID.isEmpty { state.activeSessionID = "mobile-\(credential.deviceID)" }
        let messageID = "mobu-\(UUID().uuidString.lowercased())"
        let selected = pendingAttachments
        let attachmentMetadata = selected.map {
            Attachment(name: $0.name, mimeType: $0.mimeType, size: $0.size)
        }
        let optimistic = ChatEvent.optimistic(
            messageID: messageID, sessionID: state.activeSessionID,
            text: clean.isEmpty ? "Attachment" : clean,
            replyTo: replyTarget?.id,
            threadRootID: replyTarget?.threadRootID ?? replyTarget?.id,
            attachments: attachmentMetadata
        )
        reducer.reduceOptimistic(state: &state, event: optimistic, fallbackDeviceID: credential.deviceID)
        awaitingAgentSessionIDs.insert(state.activeSessionID)
        persistSoon(); isSending = true
        do {
            let outgoing = try await AttachmentUploadHandler().prepare(selected) { [weak self] id, progress in
                guard let self, let index = self.pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
                self.pendingAttachments[index].progress = progress
            }
            guard let message = findMessage(messageID) else { throw AppError.invalidResponse }
            try await AuthenticationInterceptor(onRevoked: { [weak self] in self?.handleRevoked() }).run {
                try await MessageSendHandler(api: self.api).send(
                    credential: credential, message: message, attachments: outgoing
                )
            }
            reducer.setDelivery(state: &state, messageID: messageID, delivery: .sent)
            selected.forEach { try? FileManager.default.removeItem(at: $0.url) }
            failedAttachments.removeValue(forKey: messageID)
            pendingAttachments.removeAll(); replyTarget = nil; isSending = false; persistSoon()
            return true
        } catch {
            failedAttachments[messageID] = selected
            reducer.setDelivery(state: &state, messageID: messageID, delivery: .failed, error: error.localizedDescription)
            awaitingAgentSessionIDs.remove(state.activeSessionID)
            isSending = false; errorMessage = error.localizedDescription; persistSoon()
            return false
        }
    }

    func retry(messageID: String) async {
        guard let credential, let message = findMessage(messageID), message.deliveryState == .failed else { return }
        reducer.setDelivery(state: &state, messageID: messageID, delivery: .sending)
        awaitingAgentSessionIDs.insert(message.sessionID)
        do {
            let pending = failedAttachments[messageID] ?? []
            let attachments = try await AttachmentUploadHandler().prepare(pending) { _, _ in }
            try await MessageSendHandler(api: api).send(
                credential: credential, message: message, attachments: attachments
            )
            pending.forEach { try? FileManager.default.removeItem(at: $0.url) }
            failedAttachments.removeValue(forKey: messageID)
            pendingAttachments.removeAll { candidate in pending.contains(where: { $0.id == candidate.id }) }
            reducer.setDelivery(state: &state, messageID: messageID, delivery: .sent)
        } catch {
            reducer.setDelivery(state: &state, messageID: messageID, delivery: .failed, error: error.localizedDescription)
            awaitingAgentSessionIDs.remove(message.sessionID)
            errorMessage = error.localizedDescription
        }
        persistSoon()
    }

    func addAttachment(url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .nameKey])
            let size = values.fileSize ?? 0
            guard size <= AttachmentUploadHandler.maximumBytes else { throw AppError.attachmentTooLarge }
            let copied = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(values.name ?? url.lastPathComponent)")
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: copied)
            pendingAttachments.append(PendingAttachment(
                id: UUID(), url: copied, name: values.name ?? url.lastPathComponent,
                mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
                size: size, progress: 0
            ))
        } catch { errorMessage = error.localizedDescription }
    }

    func removeAttachment(_ item: PendingAttachment) {
        try? FileManager.default.removeItem(at: item.url)
        pendingAttachments.removeAll { $0.id == item.id }
    }

    func transcribeRecording() async -> String? {
        guard let credential else { return nil }
        do {
            let file = try voice.stop()
            voice.state = .transcribing
            defer { voice.state = .idle; try? FileManager.default.removeItem(at: file) }
            return try await TranscriptionHandler(api: api).transcribe(credential: credential, fileURL: file)
        } catch { voice.cancel(); errorMessage = error.localizedDescription; return nil }
    }

    func decide(card: WorkflowCard, decision: String) async {
        guard let credential, workflowDecisions[card.id] == nil else { return }
        workflowDecisions[card.id] = "sending"
        do {
            try await WorkflowCardHandler(api: api, persistence: persistence)
                .decide(credential: credential, card: card, decision: decision, sessionID: state.activeSessionID)
            workflowDecisions[card.id] = decision
            await refreshEvents()
        } catch {
            workflowDecisions.removeValue(forKey: card.id)
            errorMessage = error.localizedDescription
        }
    }

    func download(_ attachment: Attachment) async {
        guard let credential else { return }
        downloadingAttachmentID = attachment.id
        defer { downloadingAttachmentID = nil }
        do { downloadedFile = try await MediaDownloadHandler(api: api).download(credential: credential, attachment: attachment) }
        catch { errorMessage = error.localizedDescription }
    }

    func playAudio(_ attachment: Attachment) async {
        guard let credential else { return }
        if sessionAudioID == attachment.id {
            audio.togglePause()
            return
        }
        downloadingAttachmentID = attachment.id
        defer { downloadingAttachmentID = nil }
        do {
            let file = try await MediaDownloadHandler(api: api).download(credential: credential, attachment: attachment)
            try audio.play(id: attachment.id, fileURL: file)
            sessionAudioID = attachment.id
        } catch { errorMessage = error.localizedDescription }
    }

    func snapshot(_ attachment: Attachment) async -> UIImage? {
        guard let credential else { return nil }
        do {
            let file = try await MediaDownloadHandler(api: api).download(credential: credential, attachment: attachment)
            defer { try? FileManager.default.removeItem(at: file) }
            return UIImage(contentsOfFile: file.path)
        } catch { return nil }
    }

    func handlePush(userInfo: [AnyHashable: Any]) async {
        if let sessionID = PushNotificationHandler(api: api).sessionID(from: userInfo) { state.activeSessionID = sessionID }
        await refreshEvents()
    }

    func enablePush() async {
        do { try await PushNotificationHandler(api: api).requestAuthorization() }
        catch { errorMessage = error.localizedDescription }
    }

    #if DEBUG
    func runAttachmentTest(fileName: String, prompt: String) async {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            errorMessage = "Test attachment was not found in the app Documents directory."
            return
        }
        addAttachment(url: file)
        guard !pendingAttachments.isEmpty else { return }
        _ = await send(prompt)
    }
    #endif

    func registerPushToken(_ token: Data) async {
        guard let credential else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        try? await PushNotificationHandler(api: api).subscribe(credential: credential, token: hex)
    }

    func logout() {
        Task { await stream.stop(); await polling.stop() }
        if let credential { Task { try? await PushNotificationHandler(api: api).unsubscribe(credential: credential) } }
        credential = nil; state = ChatState(); pendingAttachments.forEach { try? FileManager.default.removeItem(at: $0.url) }
        failedAttachments.values.flatMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0.url) }
        failedAttachments.removeAll()
        pendingAttachments.removeAll(); KeychainStore.clear()
        Task { try? await persistence.clear() }
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    private func startRealtime() {
        guard let credential else { return }
        Task {
            await stream.start(credential: credential, cursor: { [weak self] in self?.state.lastEventID },
                               receive: { [weak self] event in
                                   self?.isConnected = true
                                   self?.apply([event])
                               },
                               failure: { [weak self] error in self?.handleRealtimeError(error) })
            await polling.start(credential: credential, cursor: { [weak self] in self?.state.lastEventID },
                                receive: { [weak self] events in
                                    self?.isConnected = true
                                    self?.apply(events)
                                },
                                failure: { [weak self] error in self?.handleRealtimeError(error) })
        }
    }

    private func refreshEvents() async {
        guard let credential else { return }
        do { apply(try await api.events(credential: credential, after: state.lastEventID).events); isConnected = true }
        catch let error as AppError {
            if case .revoked = error { handleRevoked() } else { isConnected = false }
        } catch { isConnected = false }
    }

    private func apply(_ events: [ChatEvent], preferred: String? = nil) {
        guard let credential else { return }
        for event in events {
            let before = state.conversations.first(where: { $0.id == event.sessionID })?.messages.count ?? 0
            reducer.reduce(state: &state, event: event, fallbackDeviceID: credential.deviceID, activeSessionID: preferred)
            clearAwaitingAgentResponse(for: event, fallbackDeviceID: credential.deviceID)
            if event.sessionID != state.activeSessionID,
               let index = state.conversations.firstIndex(where: { $0.id == event.sessionID }),
               state.conversations[index].messages.count > before {
                state.conversations[index].unreadCount += 1
            }
            if ChatEventType(rawValueOrUnknown: event.type) == .unknown {
                NSLog("Softnix unknown chat event type: %@", event.type ?? "<missing>")
            }
        }
        persistSoon()
    }

    private func rebuildFromBootstrap(_ response: BootstrapResponse, credential: AppCredential) {
        let localPending = state.conversations.flatMap(\.messages).filter {
            $0.role == .user && $0.deliveryState != .sent
        }
        state = ChatState()
        for event in response.events {
            reducer.reduce(
                state: &state, event: event, fallbackDeviceID: credential.deviceID,
                activeSessionID: response.session?.activeSessionID ?? response.activeSessionID
            )
        }
        for message in localPending where findMessage(message.id) == nil {
            reducer.reduceOptimistic(
                state: &state,
                event: .optimistic(messageID: message.id, sessionID: message.sessionID, text: message.text,
                                   replyTo: message.replyTo, threadRootID: message.threadRootID,
                                   attachments: message.attachments),
                fallbackDeviceID: credential.deviceID
            )
            reducer.setDelivery(state: &state, messageID: message.id, delivery: message.deliveryState,
                                error: message.failureReason)
        }
        if state.activeSessionID.isEmpty {
            state.activeSessionID = response.activeSessionID ?? "mobile-\(credential.deviceID)"
        }
        persistSoon()
    }

    private func handleRealtimeError(_ error: Error) {
        isConnected = false
        if case AppError.revoked = error { handleRevoked() }
    }
    private func handleRevoked() {
        errorMessage = "This device is no longer authorized. Pair it again to continue."
        logout()
    }
    private func markActiveRead() {
        guard let index = state.conversations.firstIndex(where: { $0.id == state.activeSessionID }) else { return }
        state.conversations[index].unreadCount = 0
    }
    private func findMessage(_ id: String) -> ChatMessage? {
        state.conversations.lazy.flatMap(\.messages).first { $0.id == id }
    }
    private func clearAwaitingAgentResponse(for event: ChatEvent, fallbackDeviceID: String) {
        guard (ChatRole(rawValue: event.role ?? "") ?? .agent) == .agent else { return }
        let sessionID = event.sessionID?.nilIfEmpty ?? "mobile-\(fallbackDeviceID)"
        awaitingAgentSessionIDs.remove(sessionID)
    }
    private var sessionAudioID: String? {
        get { audio.playingAttachmentID }
        set { }
    }
    private func persistSoon() {
        guard let credential else { return }
        let snapshot = state
        Task { try? await persistence.save(state: snapshot, instanceID: credential.instanceID, deviceID: credential.deviceID) }
    }
    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
}
