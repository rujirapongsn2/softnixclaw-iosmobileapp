import SwiftUI

struct AuthenticationView: View {
    @Environment(SessionStore.self) private var session
    @State private var mode: AuthMode = .pair
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var instances: [InstanceChoice] = []
    @State private var instanceSelectionPresented = false
    @State private var providers: [AuthProvider] = []
    @State private var scannerPresented = false
    @State private var oauthProvider: AuthProvider?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [SoftnixTheme.background, .white, SoftnixTheme.blue.opacity(0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        brand
                        Picker("Sign in method", selection: $mode) {
                            ForEach(AuthMode.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)

                        Group {
                            switch mode {
                            case .pair:
                                pairingForm
                            case .account:
                                accountForm
                            }
                        }
                        .padding(22)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(.white.opacity(0.8), lineWidth: 1)
                        }
                    }
                    .padding(20)
                }

                if session.isBusy {
                    ProgressView("Connecting…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .navigationDestination(isPresented: $instanceSelectionPresented) {
                InstanceSelectionView(instances: instances) { instance in
                    guard let baseURL = PairingParser.normalizedBaseURL(server) else { return }
                    await session.finishWebLogin(baseURL: baseURL, instanceID: instance.id)
                }
            }
            .sheet(isPresented: $scannerPresented) {
                QRScannerView { value in
                    scannerPresented = false
                    Task { await session.pair(rawValue: value) }
                }
            }
            .sheet(item: $oauthProvider) { provider in
                if let baseURL = PairingParser.normalizedBaseURL(server),
                   let startURL = URL(string: provider.startURL, relativeTo: baseURL) {
                    OAuthWebView(startURL: startURL, baseURL: baseURL) {
                        oauthProvider = nil
                        Task {
                            let choices = await session.finishOAuth(baseURL: baseURL)
                            if choices.count == 1, let first = choices.first {
                                await session.finishWebLogin(baseURL: baseURL, instanceID: first.id)
                            } else if !choices.isEmpty {
                                instances = choices
                                instanceSelectionPresented = true
                            }
                        }
                    }
                }
            }
        }
    }

    private var brand: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(SoftnixTheme.blue.opacity(0.14))
                    .frame(width: 112, height: 112)
                Circle()
                    .stroke(SoftnixTheme.blue.opacity(0.28), lineWidth: 1)
                    .frame(width: 92, height: 92)
                Image(systemName: "sparkles")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(SoftnixTheme.blue)
            }
            Text("Softnix")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Your native workspace assistant")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 28)
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Pair this device", systemImage: "qrcode.viewfinder")
                .font(.title3.bold())
            Text("Scan the QR code from Channels > softnix_app in the admin console.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                scannerPresented = true
            } label: {
                Label("Scan QR Code", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            TextField("Or paste pairing URL / JSON", text: $pairingCode, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)

            Button("Pair Using Code") {
                Task { await session.pair(rawValue: pairingCode) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var accountForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Sign in to Web Chat", systemImage: "person.crop.circle.badge.checkmark")
                .font(.title3.bold())
            TextField("Server URL", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            TextField("Username or email", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await login() }
            } label: {
                Text("Sign In")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(server.isEmpty || username.isEmpty || password.isEmpty)

            if !providers.isEmpty {
                Divider()
                ForEach(providers) { provider in
                    Button {
                        oauthProvider = provider
                    } label: {
                        Text(provider.label)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Load OAuth options") {
                Task { await loadProviders() }
            }
            .font(.footnote)
            .disabled(server.isEmpty)
        }
    }

    private func login() async {
        guard let baseURL = PairingParser.normalizedBaseURL(server) else {
            session.errorMessage = AppError.invalidServerURL.localizedDescription
            return
        }
        let choices = await session.login(baseURL: baseURL, username: username, password: password)
        if choices.count == 1, let first = choices.first {
            await session.finishWebLogin(baseURL: baseURL, instanceID: first.id)
        } else if !choices.isEmpty {
            instances = choices
            instanceSelectionPresented = true
        }
    }

    private func loadProviders() async {
        guard let baseURL = PairingParser.normalizedBaseURL(server) else {
            session.errorMessage = AppError.invalidServerURL.localizedDescription
            return
        }
        do {
            providers = try await APIClient().authOptions(baseURL: baseURL).authProviders
        } catch {
            session.errorMessage = error.localizedDescription
        }
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case pair
    case account

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pair: "QR Pairing"
        case .account: "Account"
        }
    }
}

private struct InstanceSelectionView: View {
    let instances: [InstanceChoice]
    let onSelect: (InstanceChoice) async -> Void

    var body: some View {
        List(instances) { instance in
            Button {
                Task { await onSelect(instance) }
            } label: {
                VStack(alignment: .leading) {
                    Text(instance.name ?? instance.id)
                    Text(instance.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Choose Workspace")
    }
}
