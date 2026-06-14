import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @State private var didRunLaunchTest = false

    var body: some View {
        Group {
            if session.credential == nil {
                AuthenticationView()
            } else {
                ChatView()
            }
        }
        .task {
            await session.restore()
            #if DEBUG
            guard !didRunLaunchTest else { return }
            didRunLaunchTest = true
            let arguments = ProcessInfo.processInfo.arguments
            if let fileIndex = arguments.firstIndex(of: "--test-attachment-file"),
               arguments.indices.contains(fileIndex + 1) {
                let promptIndex = arguments.firstIndex(of: "--test-attachment-prompt")
                let prompt = promptIndex.flatMap {
                    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
                } ?? "Please describe this image."
                await session.runAttachmentTest(fileName: arguments[fileIndex + 1], prompt: prompt)
            }
            #endif
        }
        .onOpenURL { url in
            guard session.credential == nil else { return }
            Task {
                await session.pair(rawValue: url.absoluteString)
            }
        }
        .alert(
            "Softnix",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                session.errorMessage = nil
            }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}
