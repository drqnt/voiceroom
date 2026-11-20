import AVFoundation
import LiveKit

/// Как приложение делит звук с играми.
enum AudioMode: String, CaseIterable, Identifiable {
    /// Звук игры не трогаем: без «режима звонка» iOS, эхо и шум давит WebRTC.
    case game
    /// Обычный режим звонка Apple: лучшее эхоподавление на громкой связи,
    /// но iOS немного приглушает другие приложения.
    case call

    var id: String { rawValue }

    var title: String {
        switch self {
        case .game: "Игровой"
        case .call: "Звонок"
        }
    }

    var details: String {
        switch self {
        case .game:
            "Звук игр и музыки не приглушается и не искажается. Лучше всего в наушниках."
        case .call:
            "Шумоподавление Apple, удобно без наушников. Игры звучат немного тише."
        }
    }
}

/// Настройка аудиосессии iOS. Ради этого файла всё и затевалось.
///
/// Discord и голосовые SDK по умолчанию берут у iOS сессию `.playAndRecord`
/// без `.mixWithOthers` и включают обработку голоса Apple (Voice Processing I/O).
/// Первое прерывает или глушит звук других приложений, второе приглушает его
/// и переводит громкость в «звонковую». Мы делаем наоборот:
/// - сессия смешивается с другими приложениями и никого не прерывает;
/// - в игровом режиме обработка Apple запрещена, эхо, шум и громкость
///   выравнивает программная обработка WebRTC;
/// - Bluetooth-наушники работают в музыкальном качестве (A2DP),
///   а говорим в микрофон айфона, если не включён микрофон гарнитуры.
@MainActor
enum GameAudio {
    /// Вызывается один раз при запуске, до любого подключения.
    static func prepareOnLaunch() {
        AudioManager.prepare()
        // Сессией управляем сами, SDK её не трогает.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        // Громкость своего микрофона.
        AudioManager.shared.capturePostProcessingDelegate = MicGainProcessor.shared
    }

    /// Настраивает и включает сессию перед входом в комнату.
    /// Если iOS отказывает (микрофон занят звонком или другим устройством), пробует ещё пару раз.
    static func activate(mode: AudioMode, headsetMic: Bool) async throws {
        try AudioManager.shared.setPlatformVoiceProcessingAllowed(mode == .call)
        if mode == .call {
            AudioManager.shared.isAdvancedDuckingEnabled = false
            AudioManager.shared.duckingLevel = .min
        }

        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
        if headsetMic || mode == .call {
            // Микрофон гарнитуры = «телефонный» Bluetooth (HFP), весь звук становится хуже.
            options.insert(.allowBluetoothHFP)
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: mode == .game ? .default : .voiceChat, options: options)
        try? session.setPreferredIOBufferDuration(0.02)

        var lastError: Error = AudioActivationError.unknown
        for attempt in 1 ... 3 {
            do {
                try session.setActive(true)
                log("сессия включена (попытка \(attempt)); \(diagnostics)")
                return
            } catch {
                lastError = error
                log("setActive, попытка \(attempt): \(AudioActivationError.fourCC(of: error)) \(error); \(diagnostics)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        throw AudioActivationError.failed(lastError)
    }

    /// Снова включает сессию после прерывания (входящий звонок, Siri и т.п.).
    static func reactivate() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Обработка микрофона: в игровом режиме только программная, без Apple VPIO.
    static func captureOptions(mode: AudioMode) -> AudioCaptureOptions {
        switch mode {
        case .game:
            AudioCaptureOptions(echoCancellation: true,
                                autoGainControl: true,
                                noiseSuppression: true,
                                highpassFilter: true,
                                echoCancellationMode: .software,
                                autoGainControlMode: .software,
                                noiseSuppressionMode: .software,
                                highpassFilterMode: .software)
        case .call:
            AudioCaptureOptions()
        }
    }

    /// Куда сейчас идёт звук и откуда берётся микрофон, для экрана комнаты.
    static var routeDescription: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let output = route.outputs.first.map(portName) ?? "—"
        let input = route.inputs.first.map(portName) ?? "—"
        return "Звук: \(output) · Микрофон: \(input)"
    }

    /// Какую обработку голоса реально выбрал движок (для проверки на айфоне).
    static var processingDescription: String {
        let state = AudioManager.shared.audioProcessingState
        return "Эхо: \(state.echoCancellation.effective) · Шум: \(state.noiseSuppression.effective)"
    }

    /// Состояние аудиосессии одной строкой, для логов.
    static var diagnostics: String {
        let s = AVAudioSession.sharedInstance()
        let inputs = (s.availableInputs ?? []).map(\.portName).joined(separator: ", ")
        return "category=\(s.category.rawValue) mode=\(s.mode.rawValue) otherAudio=\(s.isOtherAudioPlaying) "
            + "silenceHint=\(s.secondaryAudioShouldBeSilencedHint) mic=\(AVAudioApplication.shared.recordPermission.rawValue) "
            + "inputs=[\(inputs)] route={\(routeDescription)}"
    }

    static func log(_ message: String) {
        print("[VoiceRoom] \(message)")
        RemoteLog.shared.add(message)
    }

    private static func portName(_ port: AVAudioSessionPortDescription) -> String {
        switch port.portType {
        case .builtInSpeaker: "динамик"
        case .builtInReceiver: "разговорный динамик"
        case .builtInMic: "айфон"
        case .headphones: "проводные наушники"
        case .bluetoothA2DP: "\(port.portName) (музыкальное качество)"
        case .bluetoothHFP: "\(port.portName) (телефонное качество)"
        default: port.portName
        }
    }
}

/// Понятное объяснение, почему iOS не дала включить звук.
enum AudioActivationError: LocalizedError {
    case unknown
    case failed(Error)

    var errorDescription: String? {
        guard case let .failed(error) = self else { return "Не удалось включить звук" }
        let code = Self.fourCC(of: error)
        switch (error as NSError).code {
        case 561_017_449, 560_557_684: // '!pri', '!int'
            return "Микрофон айфона занят другим звонком: Discord, Telegram, обычный вызов или голосовой чат в игре. " +
                "Заверши его и попробуй снова. (код \(code))"
        default:
            return "Не удалось включить звук: \(error.localizedDescription) (код \(code))"
        }
    }

    /// Коды ошибок CoreAudio — это четыре символа, например '!pri'.
    static func fourCC(of error: Error) -> String {
        let code = (error as NSError).code
        guard code > 0, code <= Int(UInt32.max) else { return "\(code)" }
        let bytes = withUnsafeBytes(of: UInt32(code).bigEndian, Array.init)
        guard bytes.allSatisfy({ (32 ... 126).contains($0) }) else { return "\(code)" }
        return "'\(String(decoding: bytes, as: UTF8.self))'"
    }
}
