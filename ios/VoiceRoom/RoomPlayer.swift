import Observation
import UIKit

/// Общий плеер YouTube комнаты, как в Parallel: видео играет у каждого в своём
/// встроенном плеере, а что играет и с какого места — общее (хранит сервер,
/// присылает по каналу данных комнаты и в метаданных). Плеер продолжает играть,
/// когда приложение свёрнуто: iOS не выгружает его, пока идёт звонок.
///
/// Плееров два:
///  • звук — невидимый, простой MP4: только для него iOS даёт менять громкость;
///  • картинка — маленький плавающий плеер в хорошем качестве, без звука.
///    Есть, только пока видео показано, и идёт вровень со звуком.
@Observable
@MainActor
final class RoomPlayer {
    private(set) var current: SharedVideo?
    private(set) var queue: [SharedVideo] = []
    /// Сколько всего в очереди (в `queue` приходят только первые 20).
    private(set) var queueLength = 0
    /// Радио: когда очередь кончается, сервер сам добавляет похожие треки.
    private(set) var isRadio = false
    var error: String?

    /// Громкость плеера только у себя (0…1).
    var volume: Double = 0.5 {
        didSet { audio?.setVolume(effectiveVolume) }
    }

    /// Музыка выключена только у себя (одной кнопкой, например во время перестрелки).
    /// Друзья продолжают слушать, ролик у тебя идёт дальше беззвучно.
    var isMutedLocally = false {
        didSet { audio?.setVolume(effectiveVolume) }
    }

    private var effectiveVolume: Double { isMutedLocally ? 0 : volume }

    var isPaused: Bool { current?.pausedAt != nil }

    /// Показывать ли картинку (плавающий плеер). Только у себя.
    var isVideoVisible = false {
        didSet { if isVideoVisible != oldValue { updateVideo() } }
    }

    /// Плеер звука. Создаётся, когда в комнате включили первое видео.
    private(set) var audio: YouTubePlayer?
    /// Плеер картинки. Только пока видео показано.
    private(set) var video: YouTubePlayer?
    /// Картинка сейчас в системной «картинке в картинке» (поверх других приложений).
    private(set) var isInPictureInPicture = false

    /// Где ролик сейчас (точное время звука, иначе — по общим часам).
    var currentPosition: Double? { audioNow ?? expectedPosition }

    @ObservationIgnored private var api: API?
    @ObservationIgnored private var roomId: String?
    @ObservationIgnored private var version = -1
    /// Момент запуска сервера, от которого пришло состояние (после перезапуска версии с нуля).
    @ObservationIgnored private var epoch: Double = 0
    /// Разница часов: время сервера − время телефона (мс).
    @ObservationIgnored private var clockOffset: Double = 0
    @ObservationIgnored private var audioVideoId: String?
    @ObservationIgnored private var videoVideoId: String?
    @ObservationIgnored private var reportedEnded: String?
    @ObservationIgnored private var lastSeek = Date.distantPast
    @ObservationIgnored private var lastVideoSeek = Date.distantPast
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// До этого момента изменения состояния плееров вызваны нашими командами.
    @ObservationIgnored private var ourAudioCommandsUntil = Date.distantPast
    @ObservationIgnored private var ourVideoCommandsUntil = Date.distantPast
    /// Пока команда летит на сервер, не сверяемся (иначе отменим свою же паузу).
    @ObservationIgnored private var commandsInFlight = 0
    @ObservationIgnored private var audioTick: Tick?
    @ObservationIgnored private var videoTick: Tick?
    @ObservationIgnored private var videoRate: Double = 1
    /// Насколько картинка отстаёт сразу после перемотки (подстраивается сама).
    @ObservationIgnored private var seekLag: Double = 0.4
    @ObservationIgnored private var measureSeekLag = false
    /// Когда плееры последний раз реально продвигались (для «сторожа»).
    @ObservationIgnored private var audioProgressAt = Date()
    @ObservationIgnored private var videoProgressAt = Date()
    @ObservationIgnored private var audioRecoveries = 0
    /// Звук нового ролика хоть раз пошёл (до этого «сторож» торопится: 4 с вместо 10).
    @ObservationIgnored private var audioStarted = false
    /// Запуск после паузы в назначенный сервером момент (у всех одновременно).
    @ObservationIgnored private var scheduledPlay: Task<Void, Never>?

    /// Точное время ролика из плеера (приходит раз в полсекунды).
    private struct Tick {
        let time: Double
        let paused: Bool
        let rate: Double
        let at: Date

        var isFresh: Bool { Date().timeIntervalSince(at) < 1.5 }
        /// Где ролик сейчас, с учётом времени с последнего сообщения.
        var now: Double { paused ? time : time + Date().timeIntervalSince(at) * rate }

        init?(_ event: [String: Any]) {
            guard let time = event["t"] as? Double else { return nil }
            self.time = time
            paused = event["paused"] as? Bool ?? false
            rate = event["rate"] as? Double ?? 1
            at = (event["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        }
    }

    // MARK: - Жизненный цикл

    func start(api: API, roomId: String, volume: Double) {
        self.api = api
        self.roomId = roomId
        self.volume = volume
        // Плеер звука готовим сразу при входе: пока приложение на экране, iOS спокойно
        // встраивает его в окно и загружает. Если создавать его, только когда друг
        // включит трек, а ты в это время в игре, — он может не запуститься до возврата.
        _ = ensureAudio()
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.syncClock()
            var second = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                second += 1
                // Звук сверяем с общими часами раз в 3 секунды, картинку со звуком — каждую.
                if second % 3 == 0 { await self.reconcile(periodic: true) }
                self.syncVideo()
                self.watchdog()
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        scheduledPlay?.cancel()
        scheduledPlay = nil
        audio?.pause()
        audio = nil
        video?.pause()
        video = nil
        api = nil
        roomId = nil
        current = nil
        queue = []
        queueLength = 0
        isRadio = false
        version = -1
        epoch = 0
        audioVideoId = nil
        videoVideoId = nil
        reportedEnded = nil
        error = nil
        isMutedLocally = false
    }

    // MARK: - Состояние из комнаты

    /// Новое состояние (из канала данных, метаданных комнаты или ответа сервера).
    func apply(_ state: SharedPlayerState?) {
        guard let state else { return }
        let newVersion = state.version ?? 0
        let newEpoch = state.epoch ?? 0
        // Состояние от прошлого запуска сервера — устарело.
        if newEpoch < epoch { return }
        // Тот же запуск сервера: берём только более новое.
        if newEpoch == epoch, newVersion <= version { return }
        if newEpoch > epoch, epoch != 0 {
            // Сервер перезапускали: номера версий пошли заново. Раньше из-за этого
            // приложение молча игнорировало новые треки до перезахода в комнату.
            GameAudio.log("сервер перезапускался — принимаю новые номера версий (v\(newVersion))")
        }
        epoch = newEpoch
        version = newVersion
        current = state.current
        queue = state.queue ?? []
        queueLength = state.queueLength ?? queue.count
        isRadio = state.radio ?? false
        GameAudio.log(String(format: "состояние v%d: %@ (%.3f)", newVersion,
                             current == nil ? "пусто" : (isPaused ? "пауза" : "играет"),
                             Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
        follow()
    }

    /// Подстраивает свои плееры под общее состояние.
    private func follow() {
        guard let current else {
            audio?.pause()
            audioVideoId = nil
            updateVideo()
            return
        }
        let audio = ensureAudio()
        scheduledPlay?.cancel()
        scheduledPlay = nil
        ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
        if audioVideoId != current.videoId {
            audioVideoId = current.videoId
            audioTick = nil
            audioProgressAt = Date()
            audioRecoveries = 0
            audioStarted = false
            reportedEnded = nil
            let state = UIApplication.shared.applicationState == .active ? "на экране" : "в фоне"
            GameAudio.log(String(format: "новый ролик %@ «%@» (включил %@) с %.1f с, приложение %@, звук у себя %@",
                                 current.videoId, current.title, current.by ?? "?", expectedPosition ?? 0, state,
                                 isMutedLocally ? "ВЫКЛЮЧЕН" : "включён"))
            audio.load(videoId: current.videoId, startSeconds: expectedPosition ?? 0)
            audio.setVolume(effectiveVolume)
            updateNowPlaying()
            if isPaused { audio.pause() }
        } else if isPaused {
            // Пауза — сразу, без лишних запросов к плееру.
            audio.pause()
            Task { await reconcile(periodic: false) }
        } else if let paused = audioTick.flatMap({ $0.paused ? $0.time : nil }),
                  let expected = expectedPosition, paused - expected > 0.05
        {
            // Продолжение после паузы: сервер назначил момент чуть впереди,
            // чтобы все начали разом. Ждём его.
            let wait = min(3, paused - expected)
            scheduledPlay = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self, !self.isPaused else { return }
                self.ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
                self.ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
                self.audio?.play()
                self.video?.play()
            }
            return
        } else {
            audio.play()
            Task { await reconcile(periodic: false) }
        }
        updateVideo()
    }

    private func ensureAudio() -> YouTubePlayer {
        if let audio { return audio }
        let player = YouTubePlayer(mode: .audio)
        player.onEvent = { [weak self] event in self?.handleAudio(event) }
        audio = player
        return player
    }

    /// Создаёт или убирает плеер картинки и ставит в нём нужный ролик.
    private func updateVideo() {
        guard isVideoVisible, let current else {
            if video != nil {
                video?.pause()
                video = nil
                videoVideoId = nil
                videoTick = nil
                isInPictureInPicture = false
            }
            return
        }
        let video: YouTubePlayer
        if let existing = self.video {
            video = existing
        } else {
            video = YouTubePlayer(mode: .video)
            video.onEvent = { [weak self] event in self?.handleVideo(event) }
            self.video = video
        }
        ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
        if videoVideoId != current.videoId {
            videoVideoId = current.videoId
            videoTick = nil
            videoProgressAt = Date()
            videoRate = 1
            lastVideoSeek = Date()
            measureSeekLag = true
            video.mute()
            let start = audioNow ?? expectedPosition ?? 0
            video.load(videoId: current.videoId, startSeconds: start + (isPaused ? 0 : seekLag))
            if isPaused { video.pause() }
        } else if isPaused {
            video.pause()
        } else {
            video.play()
        }
    }

    private var audioNow: Double? {
        guard let audioTick, audioTick.isFresh else { return nil }
        return audioTick.now
    }

    /// Пауза/запуск в плеере картинки — действие человека (а не iOS): окно видно
    /// в приложении или висит в системной картинке в картинке.
    private var byUser: Bool {
        isInPictureInPicture || (isVideoVisible && UIApplication.shared.applicationState == .active)
    }

    /// Системная «картинка в картинке»: картинка висит поверх других приложений,
    /// её пауза — общая для комнаты.
    func startPictureInPicture() {
        guard let video, !isInPictureInPicture else { return }
        pipTransitionUntil = Date().addingTimeInterval(3)
        video.setPictureInPicture(true)
    }

    func stopPictureInPicture() {
        pipTransitionUntil = Date().addingTimeInterval(3)
        video?.setPictureInPicture(false)
    }

    /// Пока картинка в картинке включается или выключается, iOS сама шлёт «пауза»
    /// плееру звука — это не человек, такие команды не выполняем.
    @ObservationIgnored private var pipTransitionUntil = Date.distantPast
    @ObservationIgnored private var pipPauseCheck: Task<Void, Never>?

    /// Название и обложка ролика для острова и экрана блокировки.
    private func updateNowPlaying() {
        guard let current else { return }
        let artist = current.by.map { "VoiceRoom · включил \($0)" } ?? "VoiceRoom"
        audio?.setNowPlaying(title: current.title, artist: artist,
                             artwork: "https://i.ytimg.com/vi/\(current.videoId)/hqdefault.jpg")
    }

    /// Кнопки «Сейчас играет»: остров, экран блокировки, Пункт управления, наушники.
    private func handleRemote(_ event: [String: Any]) {
        guard current != nil else { return }
        GameAudio.log("кнопка острова: \(event["action"] ?? "?")")
        switch event["action"] as? String {
        case "play":
            if isPaused {
                Task { await setPaused(false) }
            } else {
                // У всех играет, а у себя встало — просто продолжаем.
                ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
                audio?.play()
            }
        case "pause":
            if isPaused {
                audio?.pause()
            } else if Date() < pipTransitionUntil {
                // iOS сама «ставит паузу», когда включается картинка в картинке.
                GameAudio.log("пауза от iOS при картинке в картинке — пропускаю")
            } else {
                Task { await setPaused(true) }
            }
        case "seekto":
            if let time = event["time"] as? Double { Task { await seek(to: time) } }
        case "next":
            Task { await skip() }
        default:
            break
        }
    }

    private func handleAudio(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "ready":
            audio?.setVolume(effectiveVolume)
            updateNowPlaying()
        case "remote":
            handleRemote(event)
        case "tick":
            let tick = Tick(event)
            if let tick, let previous = audioTick, !tick.paused, abs(tick.time - previous.time) > 0.05 {
                if !audioStarted {
                    audioStarted = true
                    GameAudio.log("звук пошёл (с \(String(format: "%.1f", tick.time)) с)")
                }
                audioProgressAt = Date()
                audioRecoveries = 0
            }
            audioTick = tick
        case "state":
            let state = event["state"] as? Int
            GameAudio.log("звук: состояние YouTube \(state ?? -9)\(Date() < ourAudioCommandsUntil ? " (наша команда)" : "")")
            // 0 — ролик закончился: сообщаем серверу, он включит следующий.
            if state == 0, let id = current?.videoId, reportedEnded != id {
                reportedEnded = id
                Task { _ = try? await command("ended", videoId: id) }
            }
            // Плеер звука никто не видит: если он встал сам — это iOS (сворачивание,
            // звонок), продолжаем.
            guard let current, current.pausedAt == nil, state == 2,
                  Date() > ourAudioCommandsUntil, commandsInFlight == 0 else { return }
            audio?.play()
        case "volumeHook", "level", "net", "keepAlive":
            let app = UIApplication.shared.applicationState == .background ? "в фоне" : "на экране"
            if event["event"] as? String == "level" {
                // Раз в 4 секунды: громкость звука на выходе (rms > 0 — звук реально идёт).
                GameAudio.log(String(format: "звук (%@): rms=%.3f громкость=%.2f паузa=%@ готовность=%@",
                                     app, event["rms"] as? Double ?? -1, event["gain"] as? Double ?? -1,
                                     "\(event["paused"] ?? "?")", "\(event["rs"] ?? "?")"))
            } else {
                GameAudio.log("громкость (\(app)): \(event)")
            }
        case "error":
            let code = event["code"] as? Int ?? 0
            if [100, 101, 150].contains(code), let current {
                // Ролик нельзя включить (запрещено встраивание или удалён) — пропускаем у всех.
                error = "Пропустил «\(current.title)»: автор запретил включать его в приложениях"
                Task { _ = try? await command("unplayable", videoId: current.videoId) }
            } else {
                error = "YouTube не смог включить видео (ошибка \(code))"
            }
        default:
            break
        }
    }

    private func handleVideo(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "pip":
            GameAudio.log("картинка в картинке: \(event)")
            if let mode = event["mode"] as? String, event["debug"] == nil {
                let inPiP = mode == "picture-in-picture"
                if inPiP != isInPictureInPicture { pipTransitionUntil = Date().addingTimeInterval(3) }
                isInPictureInPicture = inPiP
                // Окно картинки в картинке закрыли — картинка в приложении играет дальше.
                if !inPiP, !isPaused { video?.play() }
            }
        case "tick":
            let tick = Tick(event)
            if let tick, let previous = videoTick, !tick.paused, abs(tick.time - previous.time) > 0.05 {
                videoProgressAt = Date()
            }
            videoTick = tick
        case "state":
            let state = event["state"] as? Int
            GameAudio.log("картинка: состояние YouTube \(state ?? -9)")
            // Пауза/запуск кнопками самого плеера картинки — для всей комнаты.
            guard let current, byUser, Date() > ourVideoCommandsUntil, commandsInFlight == 0 else { return }
            if state == 2, current.pausedAt == nil {
                if isInPictureInPicture || Date() < pipTransitionUntil {
                    // В картинке в картинке пауза бывает и от iOS (когда окно закрывают).
                    // Ждём полсекунды: если окно всё ещё открыто и стоит — это человек.
                    pipPauseCheck?.cancel()
                    pipPauseCheck = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(700))
                        guard let self, !Task.isCancelled, self.isInPictureInPicture,
                              self.videoTick?.paused == true, !self.isPaused else { return }
                        await self.setPaused(true)
                    }
                } else {
                    Task { await setPaused(true) }
                }
            } else if state == 1, current.pausedAt != nil {
                Task { await setPaused(false) }
            }
        default:
            break
        }
    }

    /// Где сейчас должен быть ролик по общим часам.
    private var expectedPosition: Double? {
        guard let current else { return nil }
        if let paused = current.pausedAt { return paused }
        guard let startedAt = current.startedAt else { return nil }
        let serverNow = Date().timeIntervalSince1970 * 1000 + clockOffset
        return max(0, (serverNow - startedAt) / 1000)
    }

    private func syncClock() async {
        guard let api else { return }
        let sent = Date()
        guard let serverNow = try? await api.serverTime() else { return }
        let roundTrip = Date().timeIntervalSince(sent) * 1000
        clockOffset = serverNow + roundTrip / 2 - Date().timeIntervalSince1970 * 1000
    }

    /// Сверяет плеер звука с общим состоянием: пауза/игра и позиция.
    private func reconcile(periodic: Bool) async {
        guard commandsInFlight == 0, let audio, let current, audioVideoId == current.videoId,
              let expected = expectedPosition,
              let status = await audio.status()
        else { return }
        let state = status["state"] as? Int
        let active = UIApplication.shared.applicationState == .active
        // Время берём только точное (из самого <video>, с отметкой когда). Время из
        // YouTube API в фоне отстаёт на секунды — по нему мы «догоняли» и перематывали
        // вперёд, отсюда скачки трека после выхода из приложения.
        let time = audioNow ?? (active ? status["time"] as? Double : nil)
        if periodic {
            var line = String(format: "плеер: состояние=%d время=%.2f должно=%.2f", state ?? -9, time ?? -1, expected)
            if let video = videoTick, video.isFresh, let time {
                line += String(format: " картинка=%+.2f скорость=%.2f", video.now - time, videoRate)
            }
            GameAudio.log(line)
        }
        if current.pausedAt != nil {
            if state != 2 {
                ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
                audio.pause()
            }
            if let time, abs(time - expected) > 0.5 { audio.seek(to: expected) }
            return
        }
        // Ждём назначенного момента запуска после паузы.
        if state == 2, let time, expected < time - 0.05 { return }
        // Плеер стоит, хотя должен играть (например, после паузы у всех).
        if state == 2 || state == 5 || state == -1 {
            ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
            audio.play()
        }
        // Перематываем, только если реально разошлись, и не чаще раза в 8 секунд
        // (иначе можно мешать рекламе или загрузке). В фоне терпим больше: короткую
        // заминку при сворачивании лучше не слышать как скачок.
        let limit = active ? 1.0 : 2.5
        guard state == 1, let time, abs(time - expected) > limit else { return }
        if periodic, Date().timeIntervalSince(lastSeek) < 8 { return }
        lastSeek = Date()
        GameAudio.log(String(format: "перемотка звука: было %.2f, надо %.2f (%@)", time, expected, active ? "активно" : "в фоне"))
        ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
        audio.seek(to: expected)
    }

    /// Картинка идёт вровень со звуком: мелкие расхождения — чуть быстрее или
    /// медленнее, большие — перемоткой.
    private func syncVideo() {
        guard commandsInFlight == 0, let video, let current, videoVideoId == current.videoId,
              UIApplication.shared.applicationState == .active || isInPictureInPicture,
              let picture = videoTick, picture.isFresh
        else { return }

        if isPaused {
            setVideoRate(1)
            let target = expectedPosition ?? picture.time
            if !picture.paused {
                ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
                video.pause()
            }
            if abs(picture.time - target) > 0.3, Date().timeIntervalSince(lastVideoSeek) > 1.5 {
                lastVideoSeek = Date()
                video.seek(to: target)
            }
            return
        }

        guard let sound = audioTick, sound.isFresh, !sound.paused else { return }
        if picture.paused {
            // Картинка встала (загрузка или iOS), а звук идёт.
            if Date().timeIntervalSince(lastVideoSeek) > 3 {
                ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
                video.play()
            }
            return
        }

        let diff = picture.now - sound.now // > 0: картинка впереди звука
        if measureSeekLag, Date().timeIntervalSince(lastVideoSeek) > 2 {
            // После перемотки картинка отстала на diff: в следующий раз прыгаем дальше.
            measureSeekLag = false
            seekLag = min(2, max(0, seekLag - diff))
        }
        if abs(diff) > 1 {
            guard Date().timeIntervalSince(lastVideoSeek) > 3 else { return }
            lastVideoSeek = Date()
            measureSeekLag = true
            setVideoRate(1)
            ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
            video.seek(to: sound.now + seekLag)
        } else if abs(diff) < 0.04 {
            setVideoRate(1)
        } else {
            setVideoRate(1 - max(-0.1, min(0.1, diff * 0.25)))
        }
    }

    #if DEBUG
    func debugPip() { startPictureInPicture() }
    #endif

    /// «Сторож»: YouTube иногда так и не начинает ролик (бесконечная загрузка).
    /// Если плеер должен играть, но больше 10 секунд стоит на месте, — включаем
    /// ролик заново, а со второй попытки пересоздаём плеер целиком.
    private func watchdog() {
        guard let current, !isPaused, commandsInFlight == 0 else {
            audioProgressAt = Date()
            videoProgressAt = Date()
            return
        }
        let active = UIApplication.shared.applicationState == .active
        // Если сообщения от плеера не приходят (iOS придержал фон), это ещё не зависание.
        // Новый ролик в фоне иногда «зависает на загрузке» с первого раза и идёт со второго:
        // пока звук ещё ни разу не пошёл, повторяем через 4 секунды, потом — через 10.
        let stallLimit: TimeInterval = audioStarted ? 10 : 4
        if audio != nil, audioVideoId == current.videoId,
           Date().timeIntervalSince(audioProgressAt) > stallLimit,
           audioTick?.isFresh == true || active
        {
            audioRecoveries += 1
            audioProgressAt = Date()
            GameAudio.log("звук не идёт \(Int(stallLimit)) с — попытка \(audioRecoveries)")
            if audioRecoveries == 1 {
                ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
                audio?.load(videoId: current.videoId, startSeconds: expectedPosition ?? 0)
            } else if audioRecoveries <= 3, active {
                // Новый плеер встраивается в окно, только пока приложение на экране.
                audio?.pause()
                audio = nil
                audioVideoId = nil
                follow()
            } else if !active {
                ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
                audio?.load(videoId: current.videoId, startSeconds: expectedPosition ?? 0)
            }
        }
        if video != nil, videoVideoId == current.videoId, active,
           audioTick?.isFresh == true, audioTick?.paused == false,
           Date().timeIntervalSince(videoProgressAt) > 12
        {
            GameAudio.log("картинка не идёт 12 с — пересоздаю плеер картинки")
            video?.pause()
            video = nil
            videoVideoId = nil
            videoTick = nil
            updateVideo()
        }
    }

    private func setVideoRate(_ rate: Double) {
        guard abs(rate - videoRate) > 0.004 else { return }
        videoRate = rate
        video?.setRate(rate)
    }

    // MARK: - Команды (общие для всей комнаты)

    /// Включает видео сразу, вместо текущего.
    @discardableResult
    func playNow(_ input: String) async throws -> String {
        let reply = try await command("playNow", input: input)
        return reply.title ?? ""
    }

    /// Добавляет видео по ссылке или названию. Возвращает название.
    @discardableResult
    func add(_ input: String) async throws -> String {
        let reply = try await command("add", input: input)
        return reply.title ?? ""
    }

    /// Плейлист или микс целиком по ссылке: сразу или в конец очереди.
    @discardableResult
    func playList(_ input: String, now: Bool) async throws -> String {
        let reply = try await command("playlist", input: input, now: now)
        return reply.title ?? ""
    }

    /// Микс по текущему треку: похожие треки сразу после него, и радио включается.
    @discardableResult
    func startMix() async throws -> String {
        let reply = try await command("mix")
        return reply.title ?? ""
    }

    /// Радио вкл/выкл: докидывать ли похожие треки, когда очередь кончается.
    func setRadio(_ on: Bool) async {
        _ = try? await command("radio", on: on)
    }

    func togglePause() async {
        GameAudio.log(String(format: "нажали паузу/play (%.3f)", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))
        await setPaused(!isPaused)
    }

    /// Пауза/продолжение у всех. У себя — сразу, не дожидаясь сервера.
    private func setPaused(_ paused: Bool) async {
        guard current != nil, paused != isPaused else { return }
        ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
        ourVideoCommandsUntil = Date().addingTimeInterval(2.5)
        if paused {
            let position = audioNow ?? expectedPosition ?? 0
            audio?.pause()
            video?.pause()
            _ = try? await command("pause", position: position)
        } else {
            // Запускаем не сразу, а в момент, который назначит сервер, — вместе со всеми.
            _ = try? await command("resume")
        }
    }

    /// Перемотка у всех. У себя — сразу.
    func seek(to position: Double) async {
        guard current != nil else { return }
        let position = max(0, position)
        ourAudioCommandsUntil = Date().addingTimeInterval(2.5)
        audio?.seek(to: position)
        _ = try? await command("seek", position: position)
    }

    /// Выключает/включает музыку только у себя. Возвращает: выключена ли теперь.
    @discardableResult
    func toggleLocalMute() -> Bool {
        isMutedLocally.toggle()
        GameAudio.log("музыка у себя: \(isMutedLocally ? "ВЫКЛЮЧЕНА" : "включена")")
        return isMutedLocally
    }

    func skip() async { _ = try? await command("skip") }
    func stopAll() async { _ = try? await command("stop") }

    private func command(_ action: String, input: String? = nil, position: Double? = nil, videoId: String? = nil,
                         now: Bool? = nil, on: Bool? = nil) async throws -> PlayerReply {
        guard let api, let roomId else { throw APIError.badServerURL }
        commandsInFlight += 1
        defer { commandsInFlight -= 1 }
        let reply: PlayerReply
        do {
            reply = try await api.player(room: roomId, action: action, input: input, position: position,
                                         videoId: videoId, now: now, on: on)
        } catch {
            GameAudio.log("команда «\(action)» не прошла: \(error.localizedDescription)")
            throw error
        }
        GameAudio.log("команда «\(action)» → v\(reply.player?.version ?? -1)")
        apply(reply.player)
        return reply
    }
}
