import SwiftUI

@main
struct VoiceRoomApp: App {
    @State private var session: SessionStore
    @State private var call: CallController

    init() {
        GameAudio.prepareOnLaunch()
        _session = State(initialValue: SessionStore())
        _call = State(initialValue: CallController())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(call)
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(CallController.self) private var call
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.nick == nil {
                OnboardingView()
            } else if call.isInRoom {
                RoomView()
            } else {
                LobbyView()
            }
        }
        .animation(.default, value: call.isInRoom)
        .animation(.default, value: session.nick)
        // Журнал на сервер: по нику и устройству, раз в 5 секунд.
        .task(id: session.serverURL) {
            RemoteLog.shared.configure(api: session.api)
            GameAudio.log("приложение запущено: \(RemoteLog.shared.device), ник \(session.nick ?? "—")")
        }
        .onChange(of: scenePhase) { _, phase in
            let name = switch phase {
            case .active: "на экране"
            case .inactive: "неактивно"
            case .background: "СВЁРНУТО"
            @unknown default: "?"
            }
            GameAudio.log("приложение: \(name)")
            if phase == .background { Task { await RemoteLog.shared.flush() } }
        }
        #if DEBUG
        .task { await debugAutoStart() }
        #endif
    }

    #if DEBUG
    /// Для проверки без рук: `-autoNick Тест -autoJoin лобби` в аргументах запуска.
    private func debugAutoStart() async {
        let defaults = UserDefaults.standard
        if session.nick == nil, let nick = defaults.string(forKey: "autoNick") {
            try? await session.register(nick: nick)
        }
        if session.nick != nil, !call.isInRoom, let room = defaults.string(forKey: "autoJoin") {
            await call.join(roomId: room, session: session)
            if call.isInRoom, let song = defaults.string(forKey: "autoPlay") {
                do {
                    GameAudio.log("autoPlay: \(try await call.sharedPlayer.add(song))")
                    if UserDefaults.standard.bool(forKey: "debugPip") {
                        try? await Task.sleep(for: .seconds(15))
                        call.sharedPlayer.debugPip()
                    }
                } catch {
                    GameAudio.log("autoPlay не удался: \(error.localizedDescription)")
                }
            }
        }
    }
    #endif
}
