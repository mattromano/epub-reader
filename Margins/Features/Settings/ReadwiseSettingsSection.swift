import Persistence
import SwiftUI

/// Settings → Readwise (PLAN M7): connect a token, see what's pending, push now, disconnect.
struct ReadwiseSettingsSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var tokenField = ""
    @State private var isConnecting = false
    @State private var status: ReadwiseStatus?
    @State private var message: String?
    @State private var confirmDisconnect = false

    private var readwise: ReadwiseService { environment.readwise }

    var body: some View {
        Section {
            if readwise.isConnected {
                LabeledContent("Waiting to send", value: status.map { "\($0.pendingCount)" } ?? "–")
                LabeledContent("Last push", value: lastPushText)
                Button {
                    Task { message = await readwise.pushNow() }
                } label: {
                    HStack {
                        Text("Push to Readwise")
                        if readwise.isPushing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(readwise.isPushing)
                Button("Disconnect", role: .destructive) { confirmDisconnect = true }
            } else {
                SecureField("Access token", text: $tokenField)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    connect()
                } label: {
                    HStack {
                        Text("Connect")
                        if isConnecting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isConnecting || tokenField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Readwise")
        } footer: {
            if readwise.isConnected {
                Text("New and edited highlights go to Readwise when you push, and when you leave the app. Tags are sent with a highlight the first time only.")
            } else {
                Text("Get your token at readwise.io/access_token. It's kept in the Keychain on this iPhone.")
            }
        }
        .task(id: readwise.pushCount) { await refresh() }
        .task(id: readwise.isConnected) { await refresh() }
        .alert("Readwise", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Disconnect Readwise?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { readwise.disconnect() }
        } message: {
            Text("The token is removed from this iPhone. Highlights already in Readwise stay there.")
        }
    }

    private var lastPushText: String {
        guard let date = status?.lastPushAt.flatMap(Timestamp.date(from:)) else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private func connect() {
        isConnecting = true
        let token = tokenField
        Task {
            do {
                try await readwise.connect(token: token)
                tokenField = ""
                message = await readwise.pushNow()
            } catch {
                message = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func refresh() async {
        status = try? await readwise.status()
    }
}
