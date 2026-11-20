import Foundation
import UIKit

/// Журнал приложения на сервер. Всё, что пишет `GameAudio.log`, копится здесь и раз
/// в 5 секунд уходит на сервер (`POST /api/log`), где лежит в `server/data/logs/<ник>.log`.
/// Так после теста видно, что происходило на каждом айфоне, без пересказа.
@MainActor
final class RemoteLog {
    static let shared = RemoteLog()

    private var api: API?
    private var buffer: [API.LogLine] = []
    private var sending = false
    private var loop: Task<Void, Never>?
    /// Модель айфона, версия iOS и сборка приложения — чтобы отличать устройства в журнале.
    let device: String = {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        #if DEBUG
        let kind = "debug"
        #else
        let kind = "release"
        #endif
        return "\(model) iOS \(UIDevice.current.systemVersion) b\(build) \(kind)"
    }()

    private init() {}

    /// Куда отправлять (сервер и устройство). Без этого записи просто копятся.
    func configure(api: API?) {
        self.api = api
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.flush()
            }
        }
    }

    func add(_ message: String) {
        buffer.append(API.LogLine(t: Date().timeIntervalSince1970 * 1000, m: message))
        // Сервер недоступен долго — не копим бесконечно, старое выбрасываем.
        if buffer.count > 3000 { buffer.removeFirst(buffer.count - 3000) }
    }

    func flush() async {
        guard !sending, let api, !buffer.isEmpty else { return }
        sending = true
        defer { sending = false }
        let batch = Array(buffer.prefix(500))
        do {
            try await api.sendLog(batch, device: device)
            buffer.removeFirst(min(batch.count, buffer.count))
        } catch let APIError.server(code, _) where code == "bad_device" || code == "unknown_device" {
            // Ник ещё не выбран или устройство неизвестно — эти записи не примут.
            buffer.removeFirst(min(batch.count, buffer.count))
        } catch {
            // Нет сети — попробуем в следующий раз.
        }
    }
}
