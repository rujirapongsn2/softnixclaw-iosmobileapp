import Foundation

struct ChatState: Sendable {
    var conversations: [Conversation] = []
    var activeSessionID = ""
    var lastEventID: String?
    var seenEventIDs: Set<String> = []
}

struct ChatEventReducer {
    private let dateFormatter = ISO8601DateFormatter()

    mutating func reduce(state: inout ChatState, event: ChatEvent, fallbackDeviceID: String,
                         activeSessionID: String? = nil) {
        if let eventID = event.eventID?.nilIfEmpty {
            if state.seenEventIDs.contains(eventID) { return }
            state.seenEventIDs.insert(eventID)
            state.lastEventID = eventID
        }

        let sessionID = event.sessionID?.nilIfEmpty ?? "mobile-\(fallbackDeviceID)"
        let messageID = event.messageID?.nilIfEmpty ?? event.eventID?.nilIfEmpty ?? "unknown-\(UUID().uuidString)"
        let role = ChatRole(rawValue: event.role ?? "") ?? .agent
        let rawType = event.type ?? (role == .user ? "message" : "answer")
        let message = ChatMessage(
            id: messageID,
            eventID: event.eventID,
            role: role,
            direction: ChatDirection(rawValue: event.direction ?? "") ?? (role == .user ? .inbound : .outbound),
            eventType: ChatEventType(rawValueOrUnknown: rawType),
            rawType: rawType,
            sessionID: sessionID,
            replyTo: event.replyTo,
            threadRootID: event.threadRootID,
            text: event.text ?? event.content ?? "",
            attachments: event.attachments,
            cards: event.cards,
            metadata: event.metadata,
            timestamp: dateFormatter.date(from: event.timestamp ?? "") ?? .now,
            deliveryState: .sent,
            failureReason: nil
        )
        upsert(state: &state, message: message)
        selectActive(state: &state, preferred: activeSessionID, fallbackDeviceID: fallbackDeviceID)
    }

    mutating func reduceOptimistic(state: inout ChatState, event: ChatEvent, fallbackDeviceID: String) {
        let sessionID = event.sessionID ?? "mobile-\(fallbackDeviceID)"
        let message = ChatMessage(
            id: event.messageID ?? "mobu-\(UUID().uuidString.lowercased())",
            eventID: nil,
            role: .user,
            direction: .inbound,
            eventType: .message,
            rawType: "message",
            sessionID: sessionID,
            replyTo: event.replyTo,
            threadRootID: event.threadRootID,
            text: event.text ?? "",
            attachments: event.attachments,
            cards: [],
            metadata: [:],
            timestamp: dateFormatter.date(from: event.timestamp ?? "") ?? .now,
            deliveryState: .sending,
            failureReason: nil
        )
        upsert(state: &state, message: message)
    }

    mutating func setDelivery(state: inout ChatState, messageID: String, delivery: DeliveryState, error: String? = nil) {
        for index in state.conversations.indices {
            guard let messageIndex = state.conversations[index].messages.firstIndex(where: { $0.id == messageID }) else { continue }
            state.conversations[index].messages[messageIndex].deliveryState = delivery
            state.conversations[index].messages[messageIndex].failureReason = error
            return
        }
    }

    func timeline(for conversation: Conversation) -> [TimelineItem] {
        var result: [TimelineItem] = []
        var processing: [ToolStep] = []
        func flush() {
            guard !processing.isEmpty else { return }
            result.append(.processing(ProcessingGroup(id: "processing-\(processing[0].id)", steps: processing)))
            processing.removeAll()
        }
        for message in conversation.messages {
            if message.isProcessing {
                let operation = message.metadata["tool_name"]?.stringValue
                    ?? message.metadata["operation"]?.stringValue
                    ?? message.metadata["name"]?.stringValue
                    ?? (message.eventType == .tool ? "Tool" : "Progress")
                let status = message.metadata["status"]?.stringValue
                    ?? (message.eventType == .progress ? "running" : "completed")
                processing.append(ToolStep(id: message.id, name: operation, status: status,
                                           preview: message.text, timestamp: message.timestamp, rawType: message.rawType))
            } else {
                if message.eventType == .answer { flush() }
                else if !processing.isEmpty { flush() }
                result.append(.message(message))
            }
        }
        flush()
        return result
    }

    private func upsert(state: inout ChatState, message: ChatMessage) {
        let conversationIndex: Int
        if let existing = state.conversations.firstIndex(where: { $0.id == message.sessionID }) {
            conversationIndex = existing
        } else {
            state.conversations.append(Conversation(id: message.sessionID, messages: []))
            conversationIndex = state.conversations.endIndex - 1
        }
        if let index = state.conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id }) {
            let previous = state.conversations[conversationIndex].messages[index]
            var merged = message
            if message.text.isEmpty { merged.text = previous.text }
            if message.attachments.isEmpty { merged.attachments = previous.attachments }
            state.conversations[conversationIndex].messages[index] = merged
        } else {
            state.conversations[conversationIndex].messages.append(message)
        }
        state.conversations[conversationIndex].messages.sort {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp < $1.timestamp
        }
        state.conversations.sort {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func selectActive(state: inout ChatState, preferred: String?, fallbackDeviceID: String) {
        if let preferred, state.conversations.contains(where: { $0.id == preferred }) {
            state.activeSessionID = preferred
        } else if state.activeSessionID.isEmpty {
            state.activeSessionID = state.conversations.first?.id ?? "mobile-\(fallbackDeviceID)"
        }
    }
}
