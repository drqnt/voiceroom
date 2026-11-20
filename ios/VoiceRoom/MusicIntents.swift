import AppIntents

/// «Музыка у себя»: выключает или включает музыку комнаты только у тебя, не открывая
/// приложение. Можно повесить на касание задней панели (Настройки → Универсальный
/// доступ → Касание → Касание задней панели), кнопку действия или запускать из Команд.
struct ToggleMusicMuteIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Музыка у себя: выкл/вкл"
    static let description = IntentDescription("Выключает или включает музыку комнаты только у тебя. Друзья продолжают слушать, голос не трогается.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let call = CallController.active, call.isInRoom else {
            return .result(dialog: "Ты сейчас не в комнате VoiceRoom")
        }
        let muted = call.sharedPlayer.toggleLocalMute()
        return .result(dialog: muted ? "Музыка выключена у тебя" : "Музыка снова играет")
    }
}

/// «Пауза у всех»: ставит общий плеер комнаты на паузу или продолжает.
struct ToggleRoomPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Пауза у всех"
    static let description = IntentDescription("Ставит музыку на паузу или продолжает у всех в комнате.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let call = CallController.active, call.isInRoom, call.sharedPlayer.current != nil else {
            return .result(dialog: "Сейчас ничего не играет")
        }
        let willPause = !call.sharedPlayer.isPaused
        await call.sharedPlayer.togglePause()
        return .result(dialog: willPause ? "Пауза у всех" : "Музыка продолжается у всех")
    }
}

struct VoiceRoomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMusicMuteIntent(),
            phrases: [
                "Музыка у себя в \(.applicationName)",
                "Выключи музыку в \(.applicationName)",
                "Toggle music in \(.applicationName)",
            ],
            shortTitle: "Музыка у себя",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: ToggleRoomPauseIntent(),
            phrases: [
                "Пауза у всех в \(.applicationName)",
                "Pause music in \(.applicationName)",
            ],
            shortTitle: "Пауза у всех",
            systemImageName: "pause.fill"
        )
    }
}
