import Foundation
import SwiftData

enum SoftnixSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [StoredConversation.self, StoredMessage.self, StoredSyncState.self, StoredWorkflowDecision.self]
    }

    @Model final class StoredConversation {
        @Attribute(.unique) var sessionID: String
        var title: String
        var updatedAt: Date
        var unreadCount: Int
        init(sessionID: String, title: String, updatedAt: Date, unreadCount: Int) {
            self.sessionID = sessionID; self.title = title; self.updatedAt = updatedAt; self.unreadCount = unreadCount
        }
    }

    @Model final class StoredMessage {
        @Attribute(.unique) var messageID: String
        var eventID: String?
        var sessionID: String
        var role: String
        var direction: String
        var eventType: String
        var rawType: String
        var replyTo: String?
        var threadRootID: String?
        var text: String
        var attachmentsJSON: Data
        var cardsJSON: Data
        var metadataJSON: Data
        var timestamp: Date
        var deliveryState: String
        var failureReason: String?

        init(_ message: ChatMessage, encoder: JSONEncoder) {
            messageID = message.id; eventID = message.eventID; sessionID = message.sessionID
            role = message.role.rawValue; direction = message.direction.rawValue
            eventType = message.eventType.rawValue; rawType = message.rawType
            replyTo = message.replyTo; threadRootID = message.threadRootID; text = message.text
            attachmentsJSON = (try? encoder.encode(message.attachments.map { $0.withoutTokenizedURL })) ?? Data()
            cardsJSON = (try? encoder.encode(message.cards)) ?? Data()
            metadataJSON = (try? encoder.encode(message.metadata)) ?? Data()
            timestamp = message.timestamp; deliveryState = message.deliveryState.rawValue
            failureReason = message.failureReason
        }
    }

    @Model final class StoredSyncState {
        @Attribute(.unique) var instanceDeviceKey: String
        var activeSessionID: String
        var lastEventID: String?
        init(key: String, activeSessionID: String, lastEventID: String?) {
            instanceDeviceKey = key; self.activeSessionID = activeSessionID; self.lastEventID = lastEventID
        }
    }

    @Model final class StoredWorkflowDecision {
        @Attribute(.unique) var cardID: String
        var decision: String
        var updatedAt: Date
        init(cardID: String, decision: String) {
            self.cardID = cardID; self.decision = decision; updatedAt = .now
        }
    }
}

enum SoftnixMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SoftnixSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

actor ChatPersistence {
    private let container: ModelContainer
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(inMemory: Bool = false) throws {
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        } else {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            configuration = ModelConfiguration(url: directory.appending(path: "SoftnixMobile.store"))
        }
        container = try ModelContainer(
            for: SoftnixSchemaV1.StoredConversation.self,
            SoftnixSchemaV1.StoredMessage.self,
            SoftnixSchemaV1.StoredSyncState.self,
            SoftnixSchemaV1.StoredWorkflowDecision.self,
            migrationPlan: SoftnixMigrationPlan.self,
            configurations: configuration
        )
    }

    func load(instanceID: String, deviceID: String) throws -> ChatState {
        let context = ModelContext(container)
        let storedMessages = try context.fetch(FetchDescriptor<SoftnixSchemaV1.StoredMessage>(
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.messageID)]
        ))
        let grouped = Dictionary(grouping: storedMessages, by: \.sessionID)
        var conversations = grouped.map { sessionID, values in
            Conversation(id: sessionID, messages: values.compactMap(decodeMessage))
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
        let key = "\(instanceID):\(deviceID)"
        let states = try context.fetch(FetchDescriptor<SoftnixSchemaV1.StoredSyncState>(
            predicate: #Predicate { $0.instanceDeviceKey == key }
        ))
        let sync = states.first
        return ChatState(
            conversations: conversations,
            activeSessionID: sync?.activeSessionID ?? "",
            lastEventID: sync?.lastEventID,
            seenEventIDs: Set(storedMessages.compactMap(\.eventID))
        )
    }

    func save(state: ChatState, instanceID: String, deviceID: String) throws {
        let context = ModelContext(container)
        let existingMessages = try context.fetch(FetchDescriptor<SoftnixSchemaV1.StoredMessage>())
        let byID = Dictionary(uniqueKeysWithValues: existingMessages.map { ($0.messageID, $0) })
        for conversation in state.conversations {
            for message in conversation.messages {
                if let stored = byID[message.id] {
                    update(stored, from: message)
                } else {
                    context.insert(SoftnixSchemaV1.StoredMessage(message, encoder: encoder))
                }
            }
        }
        let key = "\(instanceID):\(deviceID)"
        let states = try context.fetch(FetchDescriptor<SoftnixSchemaV1.StoredSyncState>(
            predicate: #Predicate { $0.instanceDeviceKey == key }
        ))
        if let sync = states.first {
            sync.activeSessionID = state.activeSessionID
            sync.lastEventID = state.lastEventID
        } else {
            context.insert(SoftnixSchemaV1.StoredSyncState(
                key: key, activeSessionID: state.activeSessionID, lastEventID: state.lastEventID
            ))
        }
        try context.save()
    }

    func saveWorkflowDecision(cardID: String, decision: String) throws {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<SoftnixSchemaV1.StoredWorkflowDecision>(
            predicate: #Predicate { $0.cardID == cardID }
        ))
        if let row = rows.first { row.decision = decision; row.updatedAt = .now }
        else { context.insert(SoftnixSchemaV1.StoredWorkflowDecision(cardID: cardID, decision: decision)) }
        try context.save()
    }

    func workflowDecisions() throws -> [String: String] {
        let context = ModelContext(container)
        return Dictionary(uniqueKeysWithValues: try context.fetch(
            FetchDescriptor<SoftnixSchemaV1.StoredWorkflowDecision>()
        ).map { ($0.cardID, $0.decision) })
    }

    func clear() throws {
        let context = ModelContext(container)
        try context.delete(model: SoftnixSchemaV1.StoredConversation.self)
        try context.delete(model: SoftnixSchemaV1.StoredMessage.self)
        try context.delete(model: SoftnixSchemaV1.StoredSyncState.self)
        try context.delete(model: SoftnixSchemaV1.StoredWorkflowDecision.self)
        try context.save()
    }

    private func decodeMessage(_ stored: SoftnixSchemaV1.StoredMessage) -> ChatMessage? {
        ChatMessage(
            id: stored.messageID, eventID: stored.eventID,
            role: ChatRole(rawValue: stored.role) ?? .agent,
            direction: ChatDirection(rawValue: stored.direction) ?? .outbound,
            eventType: ChatEventType(rawValue: stored.eventType) ?? .unknown,
            rawType: stored.rawType, sessionID: stored.sessionID,
            replyTo: stored.replyTo, threadRootID: stored.threadRootID, text: stored.text,
            attachments: (try? decoder.decode([Attachment].self, from: stored.attachmentsJSON)) ?? [],
            cards: (try? decoder.decode([WorkflowCard].self, from: stored.cardsJSON)) ?? [],
            metadata: (try? decoder.decode([String: JSONValue].self, from: stored.metadataJSON)) ?? [:],
            timestamp: stored.timestamp,
            deliveryState: DeliveryState(rawValue: stored.deliveryState) ?? .sent,
            failureReason: stored.failureReason
        )
    }

    private func update(_ stored: SoftnixSchemaV1.StoredMessage, from message: ChatMessage) {
        stored.eventID = message.eventID; stored.sessionID = message.sessionID
        stored.role = message.role.rawValue; stored.direction = message.direction.rawValue
        stored.eventType = message.eventType.rawValue; stored.rawType = message.rawType
        stored.replyTo = message.replyTo; stored.threadRootID = message.threadRootID
        stored.text = message.text
        stored.attachmentsJSON = (try? encoder.encode(message.attachments.map { $0.withoutTokenizedURL })) ?? Data()
        stored.cardsJSON = (try? encoder.encode(message.cards)) ?? Data()
        stored.metadataJSON = (try? encoder.encode(message.metadata)) ?? Data()
        stored.timestamp = message.timestamp; stored.deliveryState = message.deliveryState.rawValue
        stored.failureReason = message.failureReason
    }
}

private extension Attachment {
    var withoutTokenizedURL: Attachment {
        guard let url, url.localizedCaseInsensitiveContains("mobile_token") else { return self }
        return Attachment(name: name, fileName: fileName, mimeType: mimeType, size: size, kind: kind,
                          url: nil, senderID: senderID, sourceURL: sourceURL, duration: duration)
    }
}
