import SwiftUI

/// Первый запуск: выбор ника.
struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @State private var nick = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @FocusState private var nickFocused: Bool

    private var trimmedNick: String { nick.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("VoiceRoom")
                    .font(.largeTitle.bold())
                Text("Придумай ник. По нему тебя найдут друзья.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("Ник", text: $nick)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($nickFocused)
                .onSubmit(submit)
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                Group {
                    if busy { ProgressView() } else { Text("Продолжить") }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedNick.count < 2 || busy)

            Spacer()

            DisclosureGroup("Сервер", isExpanded: $showServer) {
                TextField(SessionStore.defaultServerURL, text: $session.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.top, 8)
                Text("Обычно https://voice-room.xyz, менять не нужно.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
        }
        .padding(24)
        .onAppear { nickFocused = true }
    }

    private func submit() {
        guard trimmedNick.count >= 2, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await session.register(nick: trimmedNick)
            } catch {
                self.error = error.localizedDescription
                if (error as? APIError).map({ if case .unreachable = $0 { true } else { false } }) == true {
                    showServer = true
                }
            }
            busy = false
        }
    }
}
