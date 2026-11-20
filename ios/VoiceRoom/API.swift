import Foundation

struct TokenResponse: Decodable {
    let url: String
    let token: String
    /// Постоянный id комнаты.
    let room: String
    /// Название комнаты (можно менять).
    let name: String?
    let nick: String
}

/// Комната из списка, как канал в Discord: существует, даже когда в ней пусто.
struct SavedRoom: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let participants: [String]
}

/// Ролик в общем плеере комнаты (см. «общий плеер YouTube» в server.js).
struct SharedVideo: Codable, Equatable, Hashable {
    let videoId: String
    let title: String
    let by: String?
    /// Время сервера (мс), когда ролик был на 0:00.
    let startedAt: Double?
    /// Позиция (с), если на паузе.
    let pausedAt: Double?
}

struct SharedPlayerState: Codable, Equatable {
    /// Момент запуска сервера: после перезапуска версии начинаются заново.
    let epoch: Double?
    let version: Int?
    let current: SharedVideo?
    /// Первые 20 из очереди.
    let queue: [SharedVideo]?
    /// Сколько всего в очереди.
    let queueLength: Int?
    /// Радио: когда очередь кончается, сервер сам добавляет похожие треки.
    let radio: Bool?
}

struct PlayerReply: Decodable {
    let title: String?
    let serverNow: Double?
    let player: SharedPlayerState?
}

enum APIError: LocalizedError {
    case badServerURL
    case unreachable
    case server(code: String, message: String)

    var code: String? {
        if case let .server(code, _) = self { code } else { nil }
    }

    var errorDescription: String? {
        switch self {
        case .badServerURL: "Неверный адрес сервера"
        case .unreachable: "Сервер не отвечает. Он запущен и айфон в той же Wi-Fi сети?"
        case let .server(_, message): message
        }
    }
}

private struct ErrorReply: Decodable {
    let error: String
    let message: String
}

/// Клиент сервера ников (`server/server.js`).
struct API {
    let baseURL: URL
    let deviceId: String

    func register(nick: String) async throws -> String {
        struct Body: Encodable { let nick: String; let deviceId: String }
        struct Reply: Decodable { let nick: String }
        let reply: Reply = try await send("POST", "/api/register", body: Body(nick: nick, deviceId: deviceId))
        return reply.nick
    }

    func token(room: String) async throws -> TokenResponse {
        struct Body: Encodable { let room: String }
        return try await send("POST", "/api/token", body: Body(room: room))
    }

    /// Зовёт музыкального бота в комнату.
    func summonMusic(room: String) async throws {
        struct Body: Encodable { let room: String }
        struct Reply: Decodable { let ok: Bool }
        _ = try await send("POST", "/api/music", body: Body(room: room)) as Reply
    }

    /// Команда общему плееру: add/playNow (input), playlist (input, now), mix, radio (on),
    /// pause (position), resume, seek (position), skip, stop, ended/unplayable (videoId).
    func player(room: String, action: String, input: String? = nil, position: Double? = nil,
                videoId: String? = nil, now: Bool? = nil, on: Bool? = nil) async throws -> PlayerReply {
        struct Body: Encodable {
            let room: String
            let action: String
            let input: String?
            let position: Double?
            let videoId: String?
            let now: Bool?
            let on: Bool?
        }
        return try await send("POST", "/api/player", body: Body(room: room, action: action, input: input, position: position,
                                                                videoId: videoId, now: now, on: on))
    }

    /// Часы сервера (мс) — по ним плееры сверяют, с какого места играть.
    func serverTime() async throws -> Double {
        struct Reply: Decodable { let now: Double }
        let reply: Reply = try await send("GET", "/api/time", body: Optional<String>.none)
        return reply.now
    }

    func rooms() async throws -> [SavedRoom] {
        struct Reply: Decodable { let rooms: [SavedRoom] }
        let reply: Reply = try await send("GET", "/api/rooms", body: Optional<String>.none)
        return reply.rooms
    }

    /// Создаёт комнату. Без названия сервер назовёт её «Комната <ник>».
    func createRoom(name: String? = nil) async throws -> SavedRoom {
        struct Body: Encodable { let name: String? }
        return try await send("POST", "/api/rooms", body: Body(name: name))
    }

    func renameRoom(id: String, name: String) async throws -> SavedRoom {
        struct Body: Encodable { let name: String }
        return try await send("PATCH", "/api/rooms/\(id)", body: Body(name: name))
    }

    func deleteRoom(id: String) async throws {
        struct Reply: Decodable { let ok: Bool }
        _ = try await send("DELETE", "/api/rooms/\(id)", body: Optional<String>.none) as Reply
    }

    /// Строка журнала приложения: время (мс) и текст.
    struct LogLine: Encodable {
        let t: Double
        let m: String
    }

    /// Отправляет записи журнала на сервер (`server/data/logs/<ник>.log`).
    func sendLog(_ lines: [LogLine], device: String) async throws {
        struct Body: Encodable { let lines: [LogLine]; let device: String }
        struct Reply: Decodable { let ok: Bool }
        _ = try await send("POST", "/api/log", body: Body(lines: lines, device: device)) as Reply
    }

    private func send<Body: Encodable, Reply: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> Reply {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.unreachable
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            if let reply = try? JSONDecoder().decode(ErrorReply.self, from: data) {
                throw APIError.server(code: reply.error, message: reply.message)
            }
            throw APIError.server(code: "http_\(status)", message: "Ошибка сервера (\(status))")
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}
