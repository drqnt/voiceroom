import AVFoundation
import LiveKit
import Observation

struct Member: Identifiable, Equatable {
    let id: String
    let nick: String
    let isLocal: Bool
    let isSpeaking: Bool
    let isMuted: Bool
    /// Громкость этого человека у меня (для себя — громкость моего микрофона).
    let volume: Double
}

/// Голосовая комната: вход, выход, микрофон и список участников.
@Observable
@MainActor
final class CallController {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
    }

    private(set) var status: Status = .idle
    /// Название комнаты (меняется на лету, если кто-то переименует).
    private(set) var roomName: String?
    /// Постоянный id комнаты в LiveKit.
    private(set) var roomId: String?
    private(set) var members: [Member] = []
    private(set) var isMicOn = true
    /// Режим звука, с которым вошли в текущую комнату.
    private(set) var activeMode: AudioMode = .game
    private(set) var routeText = ""
    private(set) var processingText = ""
    var errorText: String?

    /// Старый музыкальный бот (если его вдруг запустят) не показываем среди людей.
    static let botIdentity = "music-bot"
    /// Общий плеер YouTube комнаты.
    let sharedPlayer = RoomPlayer()

    var isInRoom: Bool { status != .idle }

    /// Текущий звонок — для действий «Музыка у себя» и «Пауза у всех» из Команд,
    /// касания задней панели и кнопки действия (приложение при этом не открывается).
    static weak var active: CallController?

    init() {
        Self.active = self
    }

    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var events: RoomEvents?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeHeadsetMic = false
    /// Громкость собеседников у себя, по нику.
    private(set) var participantVolumes: [String: Double] = [:]
    /// Громкость своего микрофона (только для отображения в списке).
    private(set) var micGain: Double = 1
    /// Дорожки, которым уже выставили сохранённую громкость.
    @ObservationIgnored private var tracksWithVolume = Set<String>()
    @ObservationIgnored private var api: API?

    /// Заходит в комнату по id (или, для отладки, по названию).
    func join(roomId requested: String, name: String? = nil, session: SessionStore) async {
        guard status == .idle else { return }
        guard let api = session.api else {
            errorText = APIError.badServerURL.localizedDescription
            return
        }

        self.api = api
        status = .connecting
        errorText = nil
        roomId = requested
        roomName = name ?? requested
        activeMode = session.audioMode
        activeHeadsetMic = session.headsetMic
        participantVolumes = session.participantVolumes
        micGain = session.micGain

        do {
            let grant = try await api.token(room: requested)
            roomId = grant.room
            roomName = grant.name ?? grant.room

            guard await AVAudioApplication.requestRecordPermission() else {
                throw CallError.noMicrophonePermission
            }
            try await GameAudio.activate(mode: activeMode, headsetMic: activeHeadsetMic)

            let events = RoomEvents(
                onChange: { [weak self] in Task { @MainActor in self?.refresh() } },
                onDisconnect: { [weak self] in Task { @MainActor in self?.handleUnexpectedDisconnect() } },
                onPlayerData: { [weak self] data in Task { @MainActor in self?.applyPlayerData(data) } }
            )
            let capture = GameAudio.captureOptions(mode: activeMode)
            let room = Room(delegate: events, roomOptions: RoomOptions(defaultAudioCaptureOptions: capture))
            self.room = room
            self.events = events

            try await room.connect(url: grant.url, token: grant.token)
            try await room.localParticipant.setMicrophone(enabled: true, captureOptions: capture)

            isMicOn = true
            status = .connected
            sharedPlayer.start(api: api, roomId: grant.room, volume: session.musicVolume)
            startObservingAudioSession()
            refresh()
        } catch {
            GameAudio.log("вход в «\(requested)» не удался: \(error)")
            await room?.disconnect()
            tearDown()
            errorText = error.localizedDescription
        }
    }

    func leave() async {
        guard let room else { return }
        // Сначала сбрасываем состояние, чтобы делегат не принял выход за обрыв.
        self.room = nil
        await room.disconnect()
        tearDown()
    }

    func toggleMic() async {
        guard let room else { return }
        let target = !isMicOn
        do {
            try await room.localParticipant.setMicrophone(enabled: target,
                                                          captureOptions: GameAudio.captureOptions(mode: activeMode))
            isMicOn = target
            refresh()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var musicBot: RemoteParticipant? {
        room?.remoteParticipants.values.first { $0.identity?.stringValue == Self.botIdentity }
    }

    // MARK: - Название комнаты

    func renameRoom(to newName: String) async throws {
        guard let api, let roomId else { return }
        let room = try await api.renameRoom(id: roomId, name: newName)
        roomName = room.name
    }

    /// Метаданные комнаты от сервера: название и общий плеер.
    private func applyMetadata(_ metadata: String?) {
        struct Metadata: Decodable {
            let name: String?
            let player: SharedPlayerState?
        }
        guard let data = metadata?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Metadata.self, from: data) else { return }
        if let name = decoded.name, !name.isEmpty { roomName = name }
        sharedPlayer.apply(decoded.player)
    }

    /// Сервер сразу рассылает новое состояние плеера всем в комнате
    /// (метаданные комнаты доходят на секунду-другую позже).
    private func applyPlayerData(_ data: Data) {
        struct Message: Decodable { let player: SharedPlayerState? }
        guard let decoded = try? JSONDecoder().decode(Message.self, from: data) else { return }
        sharedPlayer.apply(decoded.player)
    }

    // MARK: - Громкость собеседников и своего микрофона

    func volume(of nick: String) -> Double {
        participantVolumes[nick] ?? 1
    }

    /// Меняет громкость человека только у себя.
    func setVolume(_ volume: Double, of nick: String) {
        participantVolumes[nick] = volume == 1 ? nil : volume
        let participant = room?.remoteParticipants.values.first { $0.identity?.stringValue == nick }
        apply(volume: volume, to: participant)
        refresh()
    }

    func setMicGain(_ gain: Double) {
        micGain = gain
        refresh()
    }

    private func apply(volume: Double, to participant: RemoteParticipant?) {
        for publication in participant?.audioTracks ?? [] {
            (publication.track as? RemoteAudioTrack)?.volume = volume
        }
    }

    /// Новым дорожкам (кто-то зашёл, бот включил музыку) сразу выставляем сохранённую громкость.
    private func applySavedVolumesToNewTracks() {
        guard let room else { return }
        for participant in room.remoteParticipants.values {
            let nick = participant.identity?.stringValue ?? ""
            for publication in participant.audioTracks {
                guard let track = publication.track as? RemoteAudioTrack,
                      !tracksWithVolume.contains(publication.sid.stringValue) else { continue }
                tracksWithVolume.insert(publication.sid.stringValue)
                track.volume = volume(of: nick)
            }
        }
    }

    // MARK: - Внутреннее

    private func refresh() {
        guard let room else { return }

        switch room.connectionState {
        case .connected: status = .connected
        case .reconnecting, .connecting: status = .reconnecting
        case .disconnected, .disconnecting: break
        }

        let bot = musicBot
        var list = [member(room.localParticipant, isLocal: true)]
        list += room.remoteParticipants.values
            .filter { $0 !== bot }
            .map { member($0, isLocal: false) }
        members = list.sorted { lhs, rhs in
            if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
            return lhs.nick.localizedCaseInsensitiveCompare(rhs.nick) == .orderedAscending
        }

        applySavedVolumesToNewTracks()
        applyMetadata(room.metadata)
        routeText = GameAudio.routeDescription
        processingText = GameAudio.processingDescription
    }

    private func member(_ participant: Participant, isLocal: Bool) -> Member {
        let nick = participant.identity?.stringValue ?? participant.name ?? "?"
        return Member(id: nick,
                      nick: nick,
                      isLocal: isLocal,
                      isSpeaking: participant.isSpeaking,
                      isMuted: isLocal ? !isMicOn : !participant.isMicrophoneEnabled(),
                      volume: isLocal ? micGain : volume(of: nick))
    }

    private func handleUnexpectedDisconnect() {
        guard room != nil else { return }
        room = nil
        tearDown()
        errorText = "Связь с комнатой потеряна"
    }

    private func tearDown() {
        stopObservingAudioSession()
        room = nil
        events = nil
        members = []
        roomName = nil
        roomId = nil
        api = nil
        sharedPlayer.stop()
        tracksWithVolume = []
        status = .idle
        GameAudio.deactivate()
    }

    private func startObservingAudioSession() {
        let center = NotificationCenter.default
        observers = [
            // Звонок, Siri, будильник: после них включаем звук обратно.
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                guard type == .ended else { return }
                Task { @MainActor in
                    GameAudio.reactivate()
                    self?.refresh()
                }
            },
            // Подключили или отключили наушники.
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            // Аудиосистема iOS перезапустилась: настраиваем сессию заново.
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    try? await GameAudio.activate(mode: self.activeMode, headsetMic: self.activeHeadsetMic)
                    self.refresh()
                }
            },
        ]
    }

    private func stopObservingAudioSession() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

enum CallError: LocalizedError {
    case noMicrophonePermission

    var errorDescription: String? {
        switch self {
        case .noMicrophonePermission:
            "Нет доступа к микрофону. Разреши его в Настройках → VoiceRoom."
        }
    }
}

/// Переходник для событий LiveKit: они приходят с фоновых потоков.
private final class RoomEvents: NSObject, RoomDelegate, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let onDisconnect: @Sendable () -> Void
    private let onPlayerData: @Sendable (Data) -> Void

    init(onChange: @escaping @Sendable () -> Void,
         onDisconnect: @escaping @Sendable () -> Void,
         onPlayerData: @escaping @Sendable (Data) -> Void)
    {
        self.onChange = onChange
        self.onDisconnect = onDisconnect
        self.onPlayerData = onPlayerData
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        if topic == "player" { onPlayerData(data) }
    }

    func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        onChange()
    }

    func room(_ room: Room, didUpdateMetadata metadata: String?) {
        onChange()
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        onDisconnect()
    }

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        onChange()
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        onChange()
    }

    func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        onChange()
    }

    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        onChange()
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        onChange()
    }

    func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        onChange()
    }

    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        onChange()
    }
}
