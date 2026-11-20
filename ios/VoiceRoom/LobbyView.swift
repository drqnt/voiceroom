import SwiftUI

/// Главный экран: список комнат (как каналы в Discord) и создание новой.
struct LobbyView: View {
    @Environment(SessionStore.self) private var session
    @Environment(CallController.self) private var call
    @State private var rooms: [SavedRoom] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var showSettings = false
    @State private var creating = false
    @State private var renaming: SavedRoom?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: createRoom) {
                        HStack {
                            Label("Создать комнату", systemImage: "plus.circle.fill")
                                .font(.headline)
                            Spacer()
                            if creating { ProgressView() }
                        }
                    }
                    .disabled(creating)
                }

                Section {
                    if rooms.isEmpty {
                        Text(loadError ?? "Загружаю комнаты…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rooms) { room in
                        Button { join(room) } label: { RoomRow(room: room) }
                            .tint(.primary)
                            .swipeActions(edge: .trailing) {
                                if room.participants.isEmpty {
                                    Button("Удалить", systemImage: "trash", role: .destructive) { delete(room) }
                                }
                                Button("Переименовать", systemImage: "pencil") { startRenaming(room) }
                                    .tint(.orange)
                            }
                            .contextMenu {
                                Button("Переименовать", systemImage: "pencil") { startRenaming(room) }
                                if room.participants.isEmpty {
                                    Button("Удалить", systemImage: "trash", role: .destructive) { delete(room) }
                                }
                            }
                    }
                } header: {
                    Text("Комнаты")
                } footer: {
                    Text("Нажми на комнату, чтобы зайти. Смахни влево, чтобы переименовать или удалить пустую.")
                }
            }
            .navigationTitle(session.nick ?? "")
            .toolbar {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Новое название", isPresented: renamingShown) {
                TextField("Название комнаты", text: $newName)
                Button("Сохранить", action: rename)
                Button("Отмена", role: .cancel) {}
            }
            .alert("Не получилось войти", isPresented: joinErrorShown) {
                Button("OK") { call.errorText = nil }
            } message: {
                Text(call.errorText ?? "")
            }
            .alert("Не получилось", isPresented: actionErrorShown) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .refreshable { await loadRooms() }
            .task {
                while !Task.isCancelled {
                    await loadRooms()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    // MARK: - Действия

    private func join(_ room: SavedRoom) {
        Task { await call.join(roomId: room.id, name: room.name, session: session) }
    }

    /// Сразу создаёт «Комната <ник>» и заходит в неё; переименовать можно потом.
    private func createRoom() {
        guard let api = session.api, !creating else { return }
        creating = true
        Task {
            do {
                let room = try await api.createRoom()
                rooms.append(room)
                join(room)
            } catch {
                actionError = error.localizedDescription
            }
            creating = false
        }
    }

    private func startRenaming(_ room: SavedRoom) {
        newName = room.name
        renaming = room
    }

    private func rename() {
        guard let room = renaming, let api = session.api else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != room.name else { return }
        Task {
            do {
                _ = try await api.renameRoom(id: room.id, name: name)
                await loadRooms()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func delete(_ room: SavedRoom) {
        guard let api = session.api else { return }
        rooms.removeAll { $0.id == room.id }
        Task {
            do {
                try await api.deleteRoom(id: room.id)
            } catch {
                actionError = error.localizedDescription
            }
            await loadRooms()
        }
    }

    private func loadRooms() async {
        guard let api = session.api else {
            loadError = APIError.badServerURL.localizedDescription
            return
        }
        do {
            rooms = try await api.rooms()
            loadError = nil
        } catch let error as APIError where error.code == "unknown_device" {
            // Сервер нас не знает (например, его данные стёрли): выбираем ник заново.
            session.nick = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Привязки для алертов

    private var renamingShown: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var joinErrorShown: Binding<Bool> {
        Binding(get: { call.errorText != nil }, set: { if !$0 { call.errorText = nil } })
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }
}

private struct RoomRow: View {
    let room: SavedRoom

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.participants.isEmpty ? "speaker.wave.1" : "speaker.wave.3.fill")
                .foregroundStyle(room.participants.isEmpty ? Color.secondary : Color.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.headline)
                Text(room.participants.isEmpty ? "Пусто" : room.participants.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !room.participants.isEmpty {
                Label("\(room.participants.count)", systemImage: "person.2.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
