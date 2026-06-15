import SwiftUI
import UniformTypeIdentifiers
import QuickLook

struct ChatView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    @State private var sidebarPresented = false
    @State private var importerPresented = false
    @State private var sharePresented = false
    @State private var isNearBottom = true

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                SoftnixWelcomeBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    connectionBanner
                    messages
                    composer
                }
                if !isNearBottom {
                    Button("Jump to latest", systemImage: "arrow.down") { isNearBottom = true }
                        .buttonStyle(.borderedProminent)
                        .padding(.trailing, 16).padding(.bottom, 110)
                }
            }
            .navigationTitle(session.credential?.instanceID ?? "Softnix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { sidebarPresented = true } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("Conversations")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New Conversation", systemImage: "square.and.pencil") { session.newConversation() }
                        Button("Enable Notifications", systemImage: "bell") { Task { await session.enablePush() } }
                        Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            session.logout()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $sidebarPresented) { ConversationListView() }
            .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(session.addAttachment) }
            }
            .sheet(isPresented: $sharePresented) {
                if let file = session.downloadedFile { QuickLookPreview(url: file) }
            }
            .onChange(of: session.downloadedFile) { _, file in if file != nil { sharePresented = true } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await session.synchronize() } }
            }
        }
    }

    private var connectionBanner: some View {
        Group {
            if !session.isConnected {
                Label("Offline. Messages will retry when the connection returns.", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(.orange.opacity(0.14))
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if session.timeline.isEmpty {
                        WelcomeView(draft: $draft)
                            .padding(.horizontal, 22)
                            .padding(.top, 36)
                    }
                    ForEach(session.timeline) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message)
                                .id(message.id)
                        case .processing(let group):
                            AgentProcessingView(group: group)
                                .id(group.id)
                        }
                    }
                    if session.isAwaitingAgentResponse && !session.isAgentRunning {
                        AgentThinkingView()
                            .id("agent-thinking")
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(.vertical, 18)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.timeline.count) {
                if isNearBottom { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            .onChange(of: session.isAwaitingAgentResponse) {
                if isNearBottom { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            .onChange(of: isNearBottom) {
                if isNearBottom { withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let reply = session.replyTarget {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replying to \(reply.role == .user ? "you" : "Softnix")").font(.caption.bold())
                        Text(reply.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { session.replyTarget = nil } label: { Image(systemName: "xmark.circle.fill") }
                }.padding(.horizontal)
            }
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(session.pendingAttachments) { item in PendingAttachmentChip(item: item) }
                    }.padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 9) {
                Button { importerPresented = true } label: { Image(systemName: "paperclip").frame(width: 34, height: 38) }
                    .accessibilityLabel("Add attachment")
                TextField("Message Softnix", text: $draft, axis: .vertical)
                    .lineLimit(1...6).padding(.horizontal, 13).padding(.vertical, 10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19))
                voiceButton
                if session.isAgentRunning {
                    Button {
                        Task { _ = await session.send("/stop") }
                    } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red).frame(width: 34, height: 38)
                    }
                    .accessibilityLabel("Stop agent task")
                }
                Button {
                    let value = draft
                    Task { if await session.send(value) { draft = "" } }
                } label: {
                    Image(systemName: "arrow.up").font(.headline.bold()).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(SoftnixTheme.blue, in: Circle())
                }
                .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingAttachments.isEmpty) || session.isSending)
                .accessibilityLabel("Send message")
            }.padding(.horizontal, 10)
            if session.voice.state == .recording {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(session.voice.elapsed, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text("Recording").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { session.voice.cancel() }
                }.font(.caption).padding(.horizontal)
            } else if session.voice.state == .transcribing {
                ProgressView("Transcribing audio…").font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var voiceButton: some View {
        Button {
            Task {
                if session.voice.state == .recording {
                    if let transcript = await session.transcribeRecording() {
                        draft = draft.isEmpty ? transcript : "\(draft) \(transcript)"
                    }
                } else {
                    do { try await session.voice.start() }
                    catch { session.errorMessage = error.localizedDescription }
                }
            }
        } label: {
            Image(systemName: session.voice.state == .recording ? "stop.fill" : "mic")
                .frame(width: 34, height: 38)
                .foregroundStyle(session.voice.state == .recording ? .red : .primary)
        }
        .disabled(session.voice.state == .transcribing)
        .accessibilityLabel(session.voice.state == .recording ? "Stop recording" : "Record voice")
    }
}

private struct WelcomeView: View {
    @Binding var draft: String
    private let actions: [WelcomeAction] = [
        .init(title: "Ask Anything", icon: "bubble.left", prompt: "Ask me anything about your workspace"),
        .init(title: "Summarize", icon: "list.bullet", prompt: "Summarize the latest information"),
        .init(title: "Schedule Task", icon: "calendar", prompt: "Help me schedule this task"),
        .init(title: "Meeting Notes", icon: "message", prompt: "Create meeting notes from this context"),
    ]

    var body: some View {
        VStack(spacing: 26) {
            SoftnixHeroLogo()
                .padding(.top, 8)

            VStack(spacing: 8) {
                Text("How can I help you today?")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(SoftnixTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                Text("Ask Softnix to analyze, summarize, plan, or work with files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 8)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14),
                ],
                spacing: 14
            ) {
                ForEach(actions) { action in
                    Button {
                        draft = action.prompt
                    } label: {
                        WelcomeActionCard(action: action)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct WelcomeAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let prompt: String
}

private struct WelcomeActionCard: View {
    let action: WelcomeAction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: action.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SoftnixTheme.blue)
                .frame(width: 42, height: 42)
                .background(SoftnixTheme.blue.opacity(0.08), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.85), lineWidth: 1)
                }
            Text(action.title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(SoftnixTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: SoftnixTheme.deepBlue.opacity(0.08), radius: 18, y: 10)
    }
}

private struct SoftnixHeroLogo: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.92),
                            SoftnixTheme.blue.opacity(0.14),
                            Color(red: 0.99, green: 0.71, blue: 0.24).opacity(0.20),
                        ],
                        center: .topLeading,
                        startRadius: 12,
                        endRadius: 142
                    )
                )
                .frame(width: 194, height: 194)
                .blur(radius: 0.2)
                .shadow(color: SoftnixTheme.blue.opacity(0.18), radius: 34, y: 18)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.24, green: 0.68, blue: 0.96).opacity(0.65),
                            Color(red: 0.55, green: 0.86, blue: 0.25).opacity(0.50),
                            Color(red: 1.0, green: 0.69, blue: 0.20).opacity(0.62),
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    lineWidth: 5
                )
                .frame(width: 190, height: 190)

            Image("SoftnixLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 116, height: 66)
                .accessibilityLabel("Softnix")
        }
        .frame(height: 210)
    }
}

private struct SoftnixWelcomeBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    SoftnixTheme.blue.opacity(0.10),
                    Color.white.opacity(0.42),
                    SoftnixTheme.deepBlue.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(SoftnixTheme.blue.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -150, y: -120)
            Circle()
                .fill(Color(red: 1.0, green: 0.73, blue: 0.28).opacity(0.10))
                .frame(width: 230, height: 230)
                .blur(radius: 80)
                .offset(x: 150, y: 90)
        }
    }
}

private struct MessageBubble: View {
    @Environment(SessionStore.self) private var session
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .agent {
                Image(systemName: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(SoftnixTheme.blue, in: Circle())
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 46)
            }
            VStack(alignment: .leading, spacing: 10) {
                if message.role == .agent {
                    Text("Softnix")
                        .font(.caption.bold())
                        .foregroundStyle(SoftnixTheme.blue)
                }
                    if message.eventType == .unknown {
                        Label("Unsupported event: \(message.rawType)", systemImage: "questionmark.diamond")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !message.text.isEmpty {
                        if message.role == .agent {
                            MarkdownMessageView(message.text)
                        } else {
                            Text(message.text)
                                .font(.body)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(message.attachments) { attachment in AttachmentView(attachment: attachment) }
                    ForEach(message.cards) { card in WorkflowCardView(card: card, sessionID: message.sessionID) }
                    HStack(spacing: 6) {
                        Text(message.timestamp, style: .time)
                        if message.deliveryState == .sending { ProgressView().controlSize(.mini) }
                        if message.deliveryState == .failed {
                            Button("Retry") { Task { await session.retry(messageID: message.id) } }
                                .font(.caption.bold())
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, message.role == .user ? 14 : 16)
            .padding(.vertical, message.role == .user ? 10 : 14)
            .frame(maxWidth: message.role == .agent ? .infinity : 292, alignment: .leading)
            .background(
                message.role == .user ? SoftnixTheme.blue : Color(.systemBackground),
                in: RoundedRectangle(cornerRadius: message.role == .user ? 18 : 16)
            )
            .overlay {
                if message.role == .agent {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(.separator).opacity(0.28))
                }
            }
            .foregroundStyle(message.role == .user ? .white : .primary)
            .shadow(color: message.role == .agent ? .black.opacity(0.035) : .clear, radius: 8, y: 2)
            if message.role == .agent { Spacer(minLength: 4) }
        }
        .padding(.horizontal, 14)
        .contextMenu {
            Button("Copy") { UIPasteboard.general.string = message.text }
            Button("Reply") { session.replyTarget = message }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message.role == .user ? "You" : "Softnix"): \(message.text)")
    }
}

private struct AgentProcessingView: View {
    let group: ProcessingGroup
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(group.steps) { step in
                    HStack(alignment: .top) {
                        Image(systemName: icon(step.status)).foregroundStyle(color(step.status))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.name).font(.subheadline.bold())
                            if !step.preview.isEmpty { Text(step.preview).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
                            Text(step.timestamp, style: .time).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }.padding(.top, 8)
        } label: {
            Label("Agent processing (\(group.steps.count))", systemImage: "gearshape.2")
        }
        .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(.separator).opacity(0.25))
        }
        .padding(.horizontal, 14)
    }
    private func icon(_ status: String) -> String {
        status == "failed" ? "xmark.circle.fill" : status == "running" ? "clock.fill" : "checkmark.circle.fill"
    }
    private func color(_ status: String) -> Color {
        status == "failed" ? .red : status == "running" ? .orange : .green
    }
}

private struct AgentThinkingView: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(SoftnixTheme.blue, in: Circle())
                .accessibilityHidden(true)
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Softnix is thinking…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(.separator).opacity(0.28))
            }
            .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Softnix is thinking")
    }
}

private struct WorkflowCardView: View {
    @Environment(SessionStore.self) private var session
    let card: WorkflowCard
    let sessionID: String
    var decision: String? { session.workflowDecisions[card.id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(card.title ?? (card.type == "workflow_preflight" ? "Dynamic Workflow" : "Workflow Approval"),
                  systemImage: "checklist")
                .font(.headline)
            if let purpose = card.purpose ?? card.request { Text(purpose).font(.subheadline) }
            if let risk = card.riskLevel { Text("Risk: \(risk.capitalized)").font(.caption.bold()) }
            ForEach(card.reasons, id: \.self) { Text("• \($0)").font(.caption) }
            if let review = card.review {
                Text(card.reviewTitle ?? "Review").font(.caption.bold())
                Text(review).font(.caption)
            }
            if let decision {
                if decision == "sending" { ProgressView("Sending decision…") }
                else { Label(decision.capitalized, systemImage: decision == "approve" ? "checkmark.circle.fill" : "xmark.circle.fill") }
            } else {
                HStack {
                    Button("Reject", role: .destructive) { Task { await session.decide(card: card, decision: "reject") } }
                        .buttonStyle(.bordered)
                    Button("Approve") { Task { await session.decide(card: card, decision: "approve") } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AttachmentView: View {
    @Environment(SessionStore.self) private var session
    let attachment: Attachment
    var body: some View {
        if attachment.senderID == "rtsp", attachment.kind == "image" {
            LiveSnapshotView(attachment: attachment)
        }
        Button {
            Task {
                if attachment.kind == "audio" { await session.playAudio(attachment) }
                else { await session.download(attachment) }
            }
        } label: {
            HStack {
                Image(systemName: attachment.kind == "image" ? "photo" :
                      attachment.kind == "audio" ? "waveform" :
                      attachment.kind == "video" ? "video" : "doc")
                VStack(alignment: .leading) {
                    Text(attachment.name).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if session.downloadingAttachmentID == attachment.id { ProgressView() }
                else if attachment.kind == "audio" {
                    Image(systemName: session.audio.playingAttachmentID == attachment.id ? "pause.circle" : "play.circle")
                } else { Image(systemName: "arrow.down.circle") }
            }
            if attachment.kind == "audio", session.audio.playingAttachmentID == attachment.id {
                Slider(value: Binding(
                    get: { session.audio.progress },
                    set: { value in session.audio.seek(value) }
                ))
            }
        }.buttonStyle(.plain)
    }
}

private struct LiveSnapshotView: View {
    @Environment(SessionStore.self) private var session
    let attachment: Attachment
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { Task { await session.download(attachment) } }
            } else {
                ProgressView("Loading live snapshot…").frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task {
            while !Task.isCancelled {
                image = await session.snapshot(attachment)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct PendingAttachmentChip: View {
    @Environment(SessionStore.self) private var session
    let item: PendingAttachment
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
            Text(item.name).lineLimit(1).frame(maxWidth: 130)
            if item.progress > 0 && item.progress < 1 { ProgressView(value: item.progress).frame(width: 28) }
            Button { session.removeAttachment(item) } label: { Image(systemName: "xmark.circle.fill") }
        }.font(.caption).padding(8).background(.thinMaterial, in: Capsule())
    }
}

private struct ConversationListView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var filtered: [Conversation] {
        search.isEmpty ? session.conversations : session.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }
    var body: some View {
        NavigationStack {
            List(filtered) { conversation in
                Button {
                    session.activeSessionID = conversation.id; dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title).lineLimit(1)
                            Text(conversation.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if conversation.unreadCount > 0 {
                            Text("\(conversation.unreadCount)").font(.caption.bold()).foregroundStyle(.white)
                                .padding(6).background(SoftnixTheme.blue, in: Circle())
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search conversations")
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New", systemImage: "square.and.pencil") { session.newConversation(); dismiss() }
                }
            }
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
