import Foundation
import Observation

/// Ник, адрес сервера и настройки звука. Хранится в UserDefaults.
///
/// Для отладки любое значение можно передать аргументом запуска,
/// например `-serverURL http://192.168.1.40:3000 -nick Тест`.
@Observable
@MainActor
final class SessionStore {
    private enum Key {
        static let deviceId = "deviceId"
        static let nick = "nick"
        static let serverURL = "serverURL"
        static let audioMode = "audioMode"
        static let headsetMic = "headsetMic"
        static let lastRoom = "lastRoom"
        static let musicVolume = "musicVolume"
        static let micGain = "micGain"
        static let showVideo = "showVideo"
        static let participantVolumes = "participantVolumes"
    }

    /// Постоянный адрес сервера (туннель Cloudflare на свой домен).
    static let defaultServerURL = "https://voice-room.xyz"

    private let defaults = UserDefaults.standard

    /// Случайный ключ этого устройства. По нему сервер узнаёт, чей это ник.
    let deviceId: String

    var nick: String? {
        didSet { defaults.set(nick, forKey: Key.nick) }
    }

    var serverURL: String {
        didSet { defaults.set(serverURL, forKey: Key.serverURL) }
    }

    var audioMode: AudioMode {
        didSet { defaults.set(audioMode.rawValue, forKey: Key.audioMode) }
    }

    var headsetMic: Bool {
        didSet { defaults.set(headsetMic, forKey: Key.headsetMic) }
    }

    var lastRoom: String {
        didSet { defaults.set(lastRoom, forKey: Key.lastRoom) }
    }

    var musicVolume: Double {
        didSet { defaults.set(musicVolume, forKey: Key.musicVolume) }
    }

    /// Показывать окно видео в комнате (иначе плеер невидимый, играет только звук).
    var showVideo: Bool {
        didSet { defaults.set(showVideo, forKey: Key.showVideo) }
    }

    /// Громкость своего микрофона для остальных: 1 = как есть.
    var micGain: Double {
        didSet {
            defaults.set(micGain, forKey: Key.micGain)
            MicGainProcessor.shared.gain = Float(micGain)
        }
    }

    /// Громкость каждого собеседника у себя, по нику: 1 = как есть.
    var participantVolumes: [String: Double] {
        didSet { defaults.set(participantVolumes, forKey: Key.participantVolumes) }
    }

    init() {
        if let saved = defaults.string(forKey: Key.deviceId) {
            deviceId = saved
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: Key.deviceId)
        }
        nick = defaults.string(forKey: Key.nick)
        // Временные адреса trycloudflare меняются при каждом перезапуске сервера:
        // такие сразу заменяем на постоянный.
        let savedURL = defaults.string(forKey: Key.serverURL)
        serverURL = (savedURL == nil || savedURL!.contains("trycloudflare.com")) ? Self.defaultServerURL : savedURL!
        audioMode = defaults.string(forKey: Key.audioMode).flatMap(AudioMode.init(rawValue:)) ?? .game
        headsetMic = defaults.bool(forKey: Key.headsetMic)
        lastRoom = defaults.string(forKey: Key.lastRoom) ?? ""
        musicVolume = (defaults.object(forKey: Key.musicVolume) as? Double) ?? 0.5
        micGain = (defaults.object(forKey: Key.micGain) as? Double) ?? 1
        showVideo = defaults.bool(forKey: Key.showVideo)
        participantVolumes = (defaults.dictionary(forKey: Key.participantVolumes) as? [String: Double]) ?? [:]
        MicGainProcessor.shared.gain = Float(micGain)
    }

    var api: API? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return API(baseURL: url, deviceId: deviceId)
    }

    /// Регистрирует или меняет ник на сервере.
    func register(nick newNick: String) async throws {
        guard let api else { throw APIError.badServerURL }
        nick = try await api.register(nick: newNick.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
