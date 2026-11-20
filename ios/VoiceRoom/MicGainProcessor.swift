import Accelerate
import Foundation
import LiveKit
import os

/// Громкость своего микрофона: умножает звук перед отправкой собеседникам.
///
/// Стоит после шумоподавления и автоусиления WebRTC, поэтому они его не «съедают».
/// Звук в этом месте — числа с плавающей точкой в диапазоне 16-битных сэмплов,
/// поэтому после усиления обрезаем по ±32767, чтобы громкий голос не хрипел сильнее.
final class MicGainProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    static let shared = MicGainProcessor()

    private let gainState = OSAllocatedUnfairLock(initialState: Float(1))

    /// 1 — без изменений, 0.5 — вдвое тише, 2 — вдвое громче.
    var gain: Float {
        get { gainState.withLock { $0 } }
        set { gainState.withLock { $0 = max(0, min(newValue, 4)) } }
    }

    var audioProcessingName: String { "voiceroom-mic-gain" }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        print("[VoiceRoom] громкость микрофона подключена: \(sampleRateHz) Гц, каналов: \(channels), усиление \(gain)")
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        var factor = gain
        guard factor != 1 else { return }
        var low: Float = -32767
        var high: Float = 32767
        let count = vDSP_Length(audioBuffer.frames)
        for channel in 0 ..< audioBuffer.channels {
            let samples = audioBuffer.rawBuffer(forChannel: channel)
            vDSP_vsmul(samples, 1, &factor, samples, 1, count)
            vDSP_vclip(samples, 1, &low, &high, samples, 1, count)
        }
    }

    func audioProcessingRelease() {}
}
