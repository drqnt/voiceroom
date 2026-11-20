import SwiftUI

/// Экран голосовой комнаты.
struct RoomView: View {
    @Environment(CallController.self) private var call
    @Environment(SessionStore.self) private var session
    @State private var volumeTarget: Member?
    @State private var showSettings = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    /// iPhone Duo: справа вертикальная полоса, кнопки живут в ней, а не внизу.
    @State private var hasSideColumn = false
    @State private var showBrowser = false
    @Environment(\.scenePhase) private var scenePhase
    /// Картинка в картинке при выходе из приложения (переключатель в настройках).
    @AppStorage("autoPictureInPicture") private var autoPictureInPicture = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if call.members.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Подключаюсь…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(call.members) { member in
                        Button { volumeTarget = member } label: {
                            MemberRow(member: member)
                        }
                        .tint(.primary)
                    }
                } header: {
                    statusHeader
                } footer: {
                    if !call.members.isEmpty {
                        Text("Нажми на человека, чтобы сделать его тише или громче у себя. На себя — громкость твоего микрофона.")
                    }
                }

                if call.status != .connecting {
                    MusicSection(showBrowser: $showBrowser)

                    Section {
                        LabeledContent("Режим", value: call.activeMode.title)
                        Text(call.routeText)
                        Text(call.processingText)
                    } header: {
                        Text("Звук")
                    } footer: {
                        Text("Можно свернуть приложение и запустить игру: голос продолжит работать.")
                    }
                    .font(.subheadline)
                }
            }
            .background {
                // Плеер звука прячется за списком (список непрозрачный). Он должен быть
                // в окне и нормального размера: крошечный или прозрачный плеер iOS
                // и YouTube не запускают, пока не покажешь видео.
                if let audio = call.sharedPlayer.audio {
                    YouTubePlayerView(player: audio)
                        .frame(width: 240, height: 240)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: session.showVideo, initial: true) {
                call.sharedPlayer.isVideoVisible = session.showVideo
            }
            .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.trailing > 30 } action: { hasSideColumn = $0 }
            .navigationTitle(call.roomName ?? "")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom) {
                if !hasSideColumn { controls }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        newName = call.roomName ?? ""
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Переименовать комнату")
                    .disabled(call.status == .connecting)

                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }

                // На iPhone Duo микрофон и выход — отдельной плашкой внизу правой полосы.
                if hasSideColumn {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            Task { await call.toggleMic() }
                        } label: {
                            Image(systemName: call.isMicOn ? "mic.fill" : "mic.slash.fill")
                        }
                        .tint(call.isMicOn ? .primary : .red)
                        .accessibilityLabel(call.isMicOn ? "Выключить микрофон" : "Включить микрофон")
                        .disabled(call.status == .connecting)

                        Button {
                            Task { await call.leave() }
                        } label: {
                            Image(systemName: "phone.down.fill")
                        }
                        .tint(.red)
                        .accessibilityLabel("Выйти из комнаты")
                    }
                }
            }
            .alert("Новое название", isPresented: $renaming) {
                TextField("Название комнаты", text: $newName)
                Button("Сохранить", action: rename)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Новое название сразу увидят все в комнате.")
            }
            .alert("Не получилось переименовать", isPresented: renameErrorShown) {
                Button("OK") { renameError = nil }
            } message: {
                Text(renameError ?? "")
            }
            .sheet(item: $volumeTarget) { VolumeSheet(member: $0) }
            #if DEBUG
            // Для проверки без рук: -debugVolumeSheet YES открывает громкость своего микрофона.
            .onChange(of: call.members.first?.id) {
                if UserDefaults.standard.bool(forKey: "debugVolumeSheet"), volumeTarget == nil {
                    volumeTarget = call.members.first
                }
            }
            #endif
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showBrowser) {
                YouTubeBrowserView { url, choice in pick(url, choice) }
            }
        }
        .overlay {
            // Маленький плеер с картинкой поверх всего экрана комнаты.
            if session.showVideo, let video = call.sharedPlayer.video {
                FloatingVideo(video: video,
                              shared: call.sharedPlayer,
                              topInset: 100,
                              bottomInset: hasSideColumn ? 12 : 100)
                {
                    session.showVideo = false
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Вышли из приложения с открытым видео — картинка уходит в системную
            // «картинку в картинке» поверх других приложений.
            if phase == .background, autoPictureInPicture, session.showVideo,
               !call.sharedPlayer.isInPictureInPicture
            {
                call.sharedPlayer.startPictureInPicture()
            }
        }
    }

    /// Видео, выбранное в окне YouTube: сразу, в очередь или весь микс/плейлист.
    private func pick(_ url: String, _ choice: YouTubeBrowserView.Pick) {
        Task {
            do {
                switch choice {
                case .now: try await call.sharedPlayer.playNow(url)
                case .queue: try await call.sharedPlayer.add(url)
                case .wholeList: try await call.sharedPlayer.playList(url, now: true)
                }
            } catch {
                call.sharedPlayer.error = error.localizedDescription
            }
        }
    }


    private var renameErrorShown: Binding<Bool> {
        Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != call.roomName else { return }
        Task {
            do {
                try await call.renameRoom(to: name)
            } catch {
                renameError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        switch call.status {
        case .connecting: Text("Подключение")
        case .reconnecting: Text("Переподключаюсь…").foregroundStyle(.orange)
        case .connected: Text("В комнате: \(call.members.count)")
        case .idle: EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button {
                Task { await call.toggleMic() }
            } label: {
                Image(systemName: call.isMicOn ? "mic.fill" : "mic.slash.fill")
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(call.isMicOn ? Color.primary : Color.white)
                    .background(call.isMicOn ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.red), in: Circle())
            }
            .accessibilityLabel(call.isMicOn ? "Выключить микрофон" : "Включить микрофон")
            .disabled(call.status == .connecting)

            Button {
                Task { await call.leave() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.white)
                    .background(Color.red, in: Circle())
            }
            .accessibilityLabel("Выйти из комнаты")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

private struct MemberRow: View {
    let member: Member

    var body: some View {
        HStack(spacing: 12) {
            Text(String(member.nick.prefix(1)).uppercased())
                .font(.headline)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.18), in: Circle())
                .overlay {
                    Circle().stroke(Color.green, lineWidth: member.isSpeaking ? 3 : 0)
                }
                .animation(.easeOut(duration: 0.15), value: member.isSpeaking)

            Text(member.isLocal ? "\(member.nick) (ты)" : member.nick)

            Spacer()

            if abs(member.volume - 1) > 0.01 {
                Text("\(Int((member.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if member.isMuted {
                Image(systemName: "mic.slash.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Микрофон выключен")
            }
        }
    }
}

/// Ползунок громкости: для собеседника — громкость у себя, для себя — громкость своего микрофона.
private struct VolumeSheet: View {
    let member: Member
    @Environment(CallController.self) private var call
    @Environment(SessionStore.self) private var session

    private var value: Binding<Double> {
        Binding(
            get: { member.isLocal ? session.micGain : call.volume(of: member.nick) },
            set: { set($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(member.isLocal ? "Громкость моего микрофона" : "Громкость: \(member.nick)")
                .font(.headline)

            HStack {
                Image(systemName: member.isLocal ? "mic" : "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: value, in: 0 ... 2, step: 0.05)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.body.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }

            HStack {
                Text(member.isLocal
                    ? "Насколько громко тебя слышат остальные."
                    : "Меняется только у тебя, \(member.nick) ничего не заметит.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить") { set(1) }
                    .disabled(abs(value.wrappedValue - 1) < 0.01)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // На iPhone Duo окно идёт и под правую полосу: пусть содержимое тоже её занимает.
        .ignoresSafeArea(.container, edges: .horizontal)
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.visible)
    }

    private func set(_ newValue: Double) {
        if member.isLocal {
            session.micGain = newValue
            call.setMicGain(newValue)
        } else {
            call.setVolume(newValue, of: member.nick)
            session.participantVolumes = call.participantVolumes
        }
    }
}
