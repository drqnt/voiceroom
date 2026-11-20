import SwiftUI

/// Блок «Видео и музыка»: общий плеер YouTube комнаты.
/// Что играет, пауза и очередь — общие; громкость — только у себя.
struct MusicSection: View {
    @Environment(CallController.self) private var call
    @Environment(SessionStore.self) private var session
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    /// Окно YouTube открывает экран комнаты: если держать его внутри списка,
    /// оно закрывается само при первом открытии.
    @Binding var showBrowser: Bool
    @FocusState private var queryFocused: Bool
    /// Вставили ссылку на плейлист/микс: спрашиваем, весь или только ролик.
    @State private var listInput: String?

    private var shared: RoomPlayer { call.sharedPlayer }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            if let current = shared.current {
                nowPlaying(current)
                Button {
                    session.showVideo.toggle()
                } label: {
                    Label(session.showVideo ? "Скрыть видео" : "Показать видео",
                          systemImage: session.showVideo ? "eye.slash" : "play.rectangle")
                }
                Button {
                    shared.toggleLocalMute()
                } label: {
                    Label(shared.isMutedLocally ? "Включить музыку у себя" : "Выключить музыку у себя",
                          systemImage: shared.isMutedLocally ? "speaker.wave.2.fill" : "speaker.slash.fill")
                }
                .tint(shared.isMutedLocally ? .red : .accentColor)
                radioRow
            } else {
                Text("Сейчас ничего не играет")
                    .foregroundStyle(.secondary)
            }

            if !shared.queue.isEmpty {
                queueList
            }

            Button {
                showBrowser = true
            } label: {
                Label("Найти на YouTube", systemImage: "play.rectangle.on.rectangle")
            }

            HStack {
                TextField("Ссылка YouTube или название", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($queryFocused)
                    .onSubmit { submit() }
                Button { submit() } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(trimmedQuery.isEmpty || busy)
                .accessibilityLabel("Включить")
            }

            HStack(spacing: 12) {
                // Выключить музыку только у себя (то же делает кнопка без входа в приложение).
                Button {
                    shared.toggleLocalMute()
                } label: {
                    Image(systemName: shared.isMutedLocally ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(shared.isMutedLocally ? Color.red : Color.secondary)
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(shared.isMutedLocally ? "Включить музыку у себя" : "Выключить музыку у себя")
                Slider(value: volume, in: 0 ... 1)
                    .accessibilityLabel("Громкость видео")
                    .disabled(shared.isMutedLocally)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            if shared.isMutedLocally {
                Text("Музыка выключена только у тебя, друзья слушают дальше.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let message = error ?? shared.error {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Видео и музыка")
        } footer: {
            Text("Видео играет у всех в комнате с одного места, пауза и очередь общие. Ползунок меняет громкость только у тебя. Музыка продолжает играть, если свернуть приложение. Ссылку на микс или плейлист YouTube можно включить целиком, а «Микс по этому треку» дальше сам подбирает похожие треки.")
        }
        .confirmationDialog("Это ссылка на плейлист или микс", isPresented: listChoiceShown, titleVisibility: .visible) {
            if let input = listInput {
                Button(input.contains("list=RD") ? "Добавить весь микс" : "Добавить весь плейлист") { addList(input) }
                Button("Только этот ролик") { add(input, now: false) }
            }
            Button("Отмена", role: .cancel) { listInput = nil }
        }
    }

    private var listChoiceShown: Binding<Bool> {
        Binding(get: { listInput != nil }, set: { if !$0 { listInput = nil } })
    }

    /// Радио: микс по текущему треку, дальше похожие треки добавляются сами.
    @ViewBuilder
    private var radioRow: some View {
        if shared.isRadio {
            Toggle(isOn: Binding(get: { shared.isRadio }, set: { on in Task { await shared.setRadio(on) } })) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Радио")
                        Text("Похожие треки добавляются сами")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                }
            }
        } else {
            Button {
                run { try await shared.startMix() }
            } label: {
                Label("Микс по этому треку", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(busy)
        }
    }

    private func nowPlaying(_ video: SharedVideo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .lineLimit(2)
                if let by = video.by {
                    Text("включил \(by)\(shared.isPaused ? " · пауза" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await shared.togglePause() }
            } label: {
                Image(systemName: shared.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(shared.isPaused ? "Продолжить" : "Пауза")
            Button {
                Task { await shared.skip() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)
            .accessibilityLabel("Следующее видео")
            Button {
                Task { await shared.stopAll() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)
            .accessibilityLabel("Остановить у всех")
        }
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Дальше")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(shared.queue.prefix(5).enumerated()), id: \.offset) { index, video in
                Text("\(index + 1). \(video.title)")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            if shared.queueLength > 5 {
                Text("и ещё \(shared.queueLength - 5)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var volume: Binding<Double> {
        Binding(get: { shared.volume }, set: {
            shared.volume = $0
            session.musicVolume = $0
        })
    }

    /// Поле ввода: ссылку на плейлист/микс уточняем, остальное — в очередь.
    private func submit() {
        let input = trimmedQuery
        guard !input.isEmpty else { return }
        if input.contains("list=") {
            listInput = input
        } else {
            add(input, now: false)
        }
    }

    private func add(_ input: String, now: Bool) {
        guard !input.isEmpty else { return }
        run {
            if now {
                try await shared.playNow(input)
            } else {
                try await shared.add(input)
            }
            query = ""
            queryFocused = false
        }
    }

    private func addList(_ input: String) {
        run {
            try await shared.playList(input, now: false)
            query = ""
            queryFocused = false
        }
    }

    /// Запрос к серверу с крутилкой и ошибкой под блоком.
    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
