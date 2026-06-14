import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct MobileCredential: Codable, Sendable, Equatable {
    let apiBaseURL: URL
    let instanceID: String
    let deviceID: String
    let deviceToken: String
    let label: String
}

struct WebCredential: Codable, Sendable, Equatable {
    let apiBaseURL: URL
    let instanceID: String
    let deviceID: String
    let csrfToken: String
    let label: String
}

enum AppCredential: Codable, Sendable, Equatable {
    case mobile(MobileCredential)
    case web(WebCredential)

    var apiBaseURL: URL {
        switch self { case .mobile(let value): value.apiBaseURL; case .web(let value): value.apiBaseURL }
    }
    var instanceID: String {
        switch self { case .mobile(let value): value.instanceID; case .web(let value): value.instanceID }
    }
    var deviceID: String {
        switch self { case .mobile(let value): value.deviceID; case .web(let value): value.deviceID }
    }
    var label: String {
        switch self { case .mobile(let value): value.label; case .web(let value): value.label }
    }
}

struct DeviceSession: Codable, Sendable, Equatable {
    let credential: AppCredential
    var activeSessionID: String?
}

struct PairingPayload: Sendable, Equatable {
    let apiBaseURL: URL
    let instanceID: String
    let token: String
}

enum ChatRole: String, Codable, Sendable { case user, agent }
enum ChatDirection: String, Codable, Sendable { case inbound, outbound }
enum ChatEventType: String, Codable, Sendable {
    case message, progress, tool, answer
    case unknown

    init(rawValueOrUnknown: String?) {
        self = ChatEventType(rawValue: rawValueOrUnknown ?? "") ?? .unknown
    }
}
enum DeliveryState: String, Codable, Sendable { case sending, sent, failed }

struct Attachment: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(senderID ?? ""):\(fileName ?? name):\(url ?? "")" }
    let name: String
    let fileName: String?
    let mimeType: String
    let size: Int
    let kind: String
    let url: String?
    let senderID: String?
    let sourceURL: String?
    let duration: Double?

    enum CodingKeys: String, CodingKey {
        case name, size, kind, url, duration
        case fileName = "file_name"
        case mimeType = "mime_type"
        case senderID = "sender_id"
        case sourceURL = "source_url"
        case type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? fileName ?? "Attachment"
        mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            ?? c.decodeIfPresent(String.self, forKey: .type) ?? "application/octet-stream"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? Self.inferKind(mimeType)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        senderID = try c.decodeIfPresent(String.self, forKey: .senderID)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
    }

    init(name: String, fileName: String? = nil, mimeType: String, size: Int, kind: String? = nil,
         url: String? = nil, senderID: String? = nil, sourceURL: String? = nil, duration: Double? = nil) {
        self.name = name
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.kind = kind ?? Self.inferKind(mimeType)
        self.url = url
        self.senderID = senderID
        self.sourceURL = sourceURL
        self.duration = duration
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(fileName, forKey: .fileName)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(size, forKey: .size)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(senderID, forKey: .senderID)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(duration, forKey: .duration)
    }

    private static func inferKind(_ mime: String) -> String {
        if mime.hasPrefix("image/") { return "image" }
        if mime.hasPrefix("audio/") { return "audio" }
        if mime.hasPrefix("video/") { return "video" }
        return "file"
    }
}

struct WorkflowCard: Codable, Identifiable, Hashable, Sendable {
    let type: String
    let intentID: String?
    let runID: String?
    let title: String?
    let request: String?
    let purpose: String?
    let reasons: [String]
    let review: String?
    let reviewTitle: String?
    let riskLevel: String?
    let estimatedSubagents: Int?
    let requiredConnectors: [String]
    let requiredTools: [String]
    let writeActions: [String]
    let scriptHash: String?
    let status: String?

    var id: String { intentID ?? runID ?? "\(type):\(title ?? "card")" }

    enum CodingKeys: String, CodingKey {
        case type, title, request, purpose, reasons, review, status
        case intentID = "intent_id"
        case runID = "run_id"
        case reviewTitle = "review_title"
        case riskLevel = "risk_level"
        case estimatedSubagents = "estimated_subagents"
        case requiredConnectors = "required_connectors"
        case requiredTools = "required_tools"
        case writeActions = "write_actions"
        case scriptHash = "script_hash"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        intentID = try c.decodeIfPresent(String.self, forKey: .intentID)
        runID = try c.decodeIfPresent(String.self, forKey: .runID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        request = try c.decodeIfPresent(String.self, forKey: .request)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        reasons = (try? c.decode([String].self, forKey: .reasons)) ?? []
        review = try c.decodeIfPresent(String.self, forKey: .review)
        reviewTitle = try c.decodeIfPresent(String.self, forKey: .reviewTitle)
        riskLevel = try c.decodeIfPresent(String.self, forKey: .riskLevel)
        estimatedSubagents = try c.decodeIfPresent(Int.self, forKey: .estimatedSubagents)
        requiredConnectors = (try? c.decode([String].self, forKey: .requiredConnectors)) ?? []
        requiredTools = (try? c.decode([String].self, forKey: .requiredTools)) ?? []
        writeActions = (try? c.decode([String].self, forKey: .writeActions)) ?? []
        scriptHash = try c.decodeIfPresent(String.self, forKey: .scriptHash)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

struct ToolStep: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: String
    let preview: String
    let timestamp: Date
    let rawType: String
}

struct ChatEvent: Codable, Hashable, Sendable {
    let eventID: String?
    let instanceID: String?
    let deviceID: String?
    let role: String?
    let direction: String?
    let type: String?
    let sessionID: String?
    let messageID: String?
    let replyTo: String?
    let threadRootID: String?
    let text: String?
    let content: String?
    let attachments: [Attachment]
    let metadata: [String: JSONValue]
    let cards: [WorkflowCard]
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case role, direction, type, text, content, attachments, metadata, cards, timestamp
        case eventID = "event_id"
        case instanceID = "instance_id"
        case deviceID = "device_id"
        case sessionID = "session_id"
        case messageID = "message_id"
        case replyTo = "reply_to"
        case threadRootID = "thread_root_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decodeIfPresent(String.self, forKey: .eventID)
        instanceID = try c.decodeIfPresent(String.self, forKey: .instanceID)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        direction = try c.decodeIfPresent(String.self, forKey: .direction)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        messageID = try c.decodeIfPresent(String.self, forKey: .messageID)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        threadRootID = try c.decodeIfPresent(String.self, forKey: .threadRootID)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        attachments = (try? c.decode([Attachment].self, forKey: .attachments)) ?? []
        metadata = (try? c.decode([String: JSONValue].self, forKey: .metadata)) ?? [:]
        let directCards = (try? c.decode([WorkflowCard].self, forKey: .cards)) ?? []
        if !directCards.isEmpty {
            cards = directCards
        } else if case .array(let values) = metadata["cards"] {
            cards = values.compactMap { value in
                guard let data = try? JSONEncoder().encode(value) else { return nil }
                return try? JSONDecoder().decode(WorkflowCard.self, from: data)
            }
        } else {
            cards = []
        }
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }

    static func optimistic(messageID: String, sessionID: String, text: String, replyTo: String?,
                           threadRootID: String?, attachments: [Attachment] = []) -> ChatEvent {
        ChatEvent(
            eventID: nil, instanceID: nil, deviceID: nil,
            role: ChatRole.user.rawValue, direction: ChatDirection.inbound.rawValue,
            type: ChatEventType.message.rawValue, sessionID: sessionID, messageID: messageID,
            replyTo: replyTo, threadRootID: threadRootID, text: text, content: nil,
            attachments: attachments, metadata: [:], cards: [],
            timestamp: ISO8601DateFormatter().string(from: .now)
        )
    }

    private init(eventID: String?, instanceID: String?, deviceID: String?, role: String?, direction: String?,
                 type: String?, sessionID: String?, messageID: String?, replyTo: String?, threadRootID: String?,
                 text: String?, content: String?, attachments: [Attachment], metadata: [String: JSONValue],
                 cards: [WorkflowCard], timestamp: String?) {
        self.eventID = eventID; self.instanceID = instanceID; self.deviceID = deviceID
        self.role = role; self.direction = direction; self.type = type; self.sessionID = sessionID
        self.messageID = messageID; self.replyTo = replyTo; self.threadRootID = threadRootID
        self.text = text; self.content = content; self.attachments = attachments
        self.metadata = metadata; self.cards = cards; self.timestamp = timestamp
    }
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    var eventID: String?
    let role: ChatRole
    let direction: ChatDirection
    let eventType: ChatEventType
    let rawType: String
    let sessionID: String
    let replyTo: String?
    let threadRootID: String?
    var text: String
    var attachments: [Attachment]
    var cards: [WorkflowCard]
    var metadata: [String: JSONValue]
    var timestamp: Date
    var deliveryState: DeliveryState
    var failureReason: String?

    var isProcessing: Bool { eventType == .progress || eventType == .tool }
}

struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    var messages: [ChatMessage]
    var unreadCount: Int = 0

    var title: String {
        let source = messages.last(where: { $0.role == .user })?.text ?? messages.last?.text ?? "New conversation"
        let compact = source.replacingOccurrences(of: "\n", with: " ")
        return compact.count > 48 ? String(compact.prefix(47)) + "…" : compact
    }
    var updatedAt: Date { messages.last?.timestamp ?? .distantPast }
}

struct ProcessingGroup: Identifiable, Hashable, Sendable {
    let id: String
    let steps: [ToolStep]
}

enum TimelineItem: Identifiable, Hashable, Sendable {
    case message(ChatMessage)
    case processing(ProcessingGroup)
    var id: String {
        switch self { case .message(let value): value.id; case .processing(let value): value.id }
    }
}

struct PendingAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let mimeType: String
    let size: Int
    var progress: Double
}

struct OutgoingAttachment: Encodable, Sendable {
    let name: String
    let type: String
    let size: Int
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case name, type, size
        case dataBase64 = "data_base64"
    }
}

struct AuthOptions: Decodable, Sendable {
    let enabled: Bool
    let authProviders: [AuthProvider]
    enum CodingKeys: String, CodingKey { case enabled; case authProviders = "auth_providers" }
}
struct AuthProvider: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let startURL: String
    enum CodingKeys: String, CodingKey { case id, label; case startURL = "start_url" }
}
struct InstanceChoice: Decodable, Identifiable, Hashable, Sendable { let id: String; let name: String? }
struct PasswordLoginResponse: Decodable, Sendable { let instances: [InstanceChoice] }
struct BootstrapResponse: Decodable, Sendable {
    let events: [ChatEvent]
    let activeSessionID: String?
    let device: BootstrapDevice?
    let session: BootstrapSession?
    enum CodingKeys: String, CodingKey {
        case events, device, session
        case activeSessionID = "active_session_id"
    }
}
struct BootstrapDevice: Decodable, Sendable {
    let instanceID: String
    let deviceID: String
    let label: String?
    enum CodingKeys: String, CodingKey { case label; case instanceID = "instance_id"; case deviceID = "device_id" }
}
struct BootstrapSession: Decodable, Sendable {
    let csrfToken: String?
    let activeSessionID: String?
    enum CodingKeys: String, CodingKey { case csrfToken = "csrf_token"; case activeSessionID = "active_session_id" }
}
struct EventsResponse: Decodable, Sendable { let events: [ChatEvent] }
struct MobileRegistrationResponse: Decodable, Sendable {
    let deviceToken: String
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token" }
}
struct MessageResponse: Decodable, Sendable {
    let messageID: String
    let sessionID: String
    let attachments: [Attachment]?
    enum CodingKeys: String, CodingKey { case attachments; case messageID = "message_id"; case sessionID = "session_id" }
}
struct TranscriptionResponse: Decodable, Sendable { let transcript: String }
struct ServerErrorPayload: Decodable, Sendable { let error: String?; let errorCode: String?; let status: String?
    enum CodingKeys: String, CodingKey { case error, status; case errorCode = "error_code" }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
