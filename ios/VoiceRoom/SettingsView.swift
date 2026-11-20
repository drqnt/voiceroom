import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(CallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var newNick = ""
    @State private var nickError: String?
    @State private var busy = false
    @AppStorage("autoPictureInPicture") private var autoPictureInPicture = true

    var body: some View {
        @Bindable var session = session

        NavigationStack {
            Form {
                Section {
                    Picker("Режим звука", selection: $session.audioMode) {
                        ForEach(AudioMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(session.audioMode.details)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Микрофон Bluetooth-наушников", isOn: $session.headsetMic)
                } header: {
                    Text("Звук")
                } footer: {
                    Text("Выключено: в AirPods полное качество, а говоришь в микрофон айфона. Включено: говоришь в наушники, но весь звук, включая игру, становится «телефонным». Режим и микрофон наушников применятся при следующем входе в комнату.")
                }

                Section {
                    HStack {
                        Image(systemName: "mic")
                            .foregroundStyle(.secondary)
                        Slider(value: micGain, in: 0 ... 2, step: 0.05)
                        Text("\(Int((session.micGain * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                } header: {
                    Text("Громкость моего микрофона")
                } footer: {
                    Text("Насколько громко тебя слышат остальные. Меняется сразу, даже посреди разговора.")
                }

                Section {
                    Label("Двойное касание спинки айфона — музыка выкл/вкл у тебя", systemImage: "hand.tap")
                    Text("1. Открой Настройки → Универсальный доступ → Касание → Касание задней панели.\n2. Выбери «Двойное касание» и в разделе «Быстрые команды» — «Музыка у себя».\nЕсли её там нет: в приложении «Команды» нажми «+», добавь действие «Музыка у себя» из VoiceRoom и сохрани.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("На айфонах с кнопкой действия: Настройки → Кнопка действия → Команда → «Музыка у себя». Так же есть «Пауза у всех».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Музыка одной кнопкой")
                } footer: {
                    Text("Работает, пока ты в комнате, даже из игры — приложение открывать не нужно. В острове и на экране блокировки пауза, перемотка и «дальше» тоже общие для всей комнаты.")
                }

                Section {
                    Toggle("Картинка в картинке при выходе", isOn: $autoPictureInPicture)
                } header: {
                    Text("Видео")
                } footer: {
                    Text("Если видео показано и ты выходишь из приложения, оно остаётся маленьким окном поверх других приложений. Пауза в этом окне — у всех в комнате.")
                }

                Section {
                    TextField("Новый ник", text: $newNick)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Сменить ник", action: changeNick)
                        .disabled(busy || call.isInRoom || newNick.trimmingCharacters(in: .whitespaces).count < 2 || newNick == session.nick)
                    if call.isInRoom {
                        Text("Ник можно сменить, когда выйдешь из комнаты.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let nickError {
                        Text(nickError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Ник")
                }

                Section {
                    TextField(SessionStore.defaultServerURL, text: $session.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Сервер")
                } footer: {
                    Text("Обычно https://voice-room.xyz, менять не нужно.")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { newNick = session.nick ?? "" }
        }
    }

    private var micGain: Binding<Double> {
        Binding(get: { session.micGain }, set: {
            session.micGain = $0
            call.setMicGain($0)
        })
    }

    private func changeNick() {
        busy = true
        nickError = nil
        Task {
            do {
                try await session.register(nick: newNick)
            } catch {
                nickError = error.localizedDescription
            }
            busy = false
        }
    }
}
