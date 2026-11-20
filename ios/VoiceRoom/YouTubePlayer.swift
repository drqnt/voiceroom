import SwiftUI
import WebKit

/// Встроенный плеер YouTube (официальный IFrame API) внутри приложения.
///
/// Страница плеера живёт на нашем сервере (`server/public/player.html`): YouTube
/// требует, чтобы встроенный плеер открывался с настоящего сайта.
@MainActor
final class YouTubePlayer: NSObject, WKScriptMessageHandler {
    enum Mode {
        /// Невидимый плеер для звука: простой MP4 и свой регулятор громкости.
        case audio
        /// Плеер для картинки в HD, без звука (звук даёт плеер .audio).
        case video
    }

    let mode: Mode
    static let pageURL = URL(string: "https://voice-room.xyz/player.html")!
    private var pageURL: URL {
        mode == .video ? URL(string: "?mode=video", relativeTo: Self.pageURL)!.absoluteURL : Self.pageURL
    }

    let webView: WKWebView
    /// События плеера: ready, state (YouTube: -1…5), error, visibility.
    var onEvent: (([String: Any]) -> Void)?
    /// Пока страница плеера не загрузилась, команды копятся здесь.
    private var isReady = false
    private var pending: [String] = []

    init(mode: Mode) {
        self.mode = mode
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Системная картинка в картинке — только для плеера картинки.
        config.allowsPictureInPictureMediaPlayback = mode == .video
        if mode == .video {
            // Отдельный процесс для картинки: в общем процессе WebKit плеер звука
            // не стартует, пока играет второй ролик.
            config.websiteDataStore = .nonPersistent()
        }
        let controller = WKUserContentController()
        // Во всех кадрах, включая плеер youtube.com: страница всегда «видима»,
        // чтобы плеер не вставал на паузу, когда приложение уходит в фон.
        controller.addUserScript(WKUserScript(source: Self.alwaysVisibleScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        // Громкость: iOS не даёт менять громкость видео напрямую, поэтому внутри
        // плеера youtube.com пускаем звук ролика через свой регулятор (Web Audio).
        if mode == .audio {
            controller.addUserScript(WKUserScript(source: Self.volumeScript,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
            // Кнопки в острове и на экране блокировки — общие для комнаты.
            controller.addUserScript(WKUserScript(source: Self.mediaSessionScript,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
        // Точное время ролика прямо из <video> — чтобы картинка шла вровень со звуком.
        controller.addUserScript(WKUserScript(source: Self.timeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        // Обход для громкости: без MediaSource/HLS и с «компьютерным» браузером YouTube
        // переходит на простой MP4, а для него iOS пропускает звук через Web Audio
        // (для потоковых форматов не пропускает — давний баг WebKit 180696).
        // Отключить для проверки: -ytProgressive NO.
        let progressive = mode == .audio && (UserDefaults.standard.object(forKey: "ytProgressive") as? Bool ?? true)
        if progressive {
            controller.addUserScript(WKUserScript(source: """
            for (const name of ['MediaSource', 'ManagedMediaSource', 'WebKitMediaSource']) {
              try { Object.defineProperty(window, name, { value: undefined, configurable: true, writable: true }); } catch (e) {}
            }
            // Просим файл с разрешением CORS, иначе Web Audio получит вместо звука тишину.
            const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            Object.defineProperty(HTMLMediaElement.prototype, 'src', {
              configurable: true,
              get() { return srcDescriptor.get.call(this); },
              set(value) { try { this.crossOrigin = 'anonymous'; } catch (e) {} srcDescriptor.set.call(this, value); },
            });
            const setAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function (name, value) {
              if (this instanceof HTMLMediaElement && String(name).toLowerCase() === 'src') {
                try { this.crossOrigin = 'anonymous'; } catch (e) {}
              }
              return setAttribute.call(this, name, value);
            };
            const canPlay = HTMLMediaElement.prototype.canPlayType;
            HTMLMediaElement.prototype.canPlayType = function (type) {
              return /mpegurl|m3u8|hls/i.test(String(type)) ? '' : canPlay.call(this, type);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        webView = EdgeToEdgeWebView(frame: .zero, configuration: config)
        if progressive {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        super.init()
        controller.add(WeakMessageHandler(target: self), name: "player")
        webView.load(URLRequest(url: pageURL))
    }

    /// Внутри плеера youtube.com: кнопки «Сейчас играет» (остров, экран блокировки,
    /// Пункт управления) не трогают ролик сами, а передаются приложению — оно делает
    /// паузу, перемотку и «дальше» сразу у всей комнаты. Обработчики YouTube не ставим,
    /// название и обложку задаёт приложение.
    private static let mediaSessionScript = """
    (() => {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      const session = navigator.mediaSession;
      if (!session || typeof MediaSession === 'undefined') return;
      const post = (m) => { try { window.webkit.messageHandlers.player.postMessage(m); } catch (e) {} };
      const setHandler = MediaSession.prototype.setActionHandler;
      const ours = {
        play: () => post({ event: 'remote', action: 'play' }),
        pause: () => post({ event: 'remote', action: 'pause' }),
        stop: () => post({ event: 'remote', action: 'pause' }),
        seekto: (details) => post({ event: 'remote', action: 'seekto', time: details && details.seekTime }),
        nexttrack: () => post({ event: 'remote', action: 'next' }),
      };
      const install = () => {
        for (const [action, handler] of Object.entries(ours)) {
          try { setHandler.call(session, action, handler); } catch (e) {}
        }
        for (const action of ['previoustrack', 'seekbackward', 'seekforward', 'skipad']) {
          try { setHandler.call(session, action, null); } catch (e) {}
        }
      };
      // YouTube свои обработчики поставить не сможет.
      session.setActionHandler = () => {};
      install();
      setInterval(install, 5000);
      const metadata = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
      let ourMetadata = null;
      if (metadata && metadata.set) {
        Object.defineProperty(session, 'metadata', {
          configurable: true,
          get: () => metadata.get.call(session),
          set: (value) => { if (!ourMetadata) metadata.set.call(session, value); },
        });
      }
      window.addEventListener('message', (e) => {
        const info = e.data && e.data.vrNowPlaying;
        if (!info || !metadata || !metadata.set) return;
        try {
          ourMetadata = new MediaMetadata({
            title: info.title || '',
            artist: info.artist || '',
            album: info.album || '',
            artwork: info.artwork ? [{ src: info.artwork, sizes: '480x360', type: 'image/jpeg' }] : [],
          });
          metadata.set.call(session, ourMetadata);
        } catch (err) {}
      });
    })();
    """

    /// Внутри плеера youtube.com: раз в полсекунды сообщает точное время ролика
    /// и умеет чуть ускорять/замедлять картинку (vrRate).
    private static let timeScript = """
    (() => {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      let rate = 1;
      // YouTube запрещает картинку в картинке во встроенном плеере и ставит запрет
      // снова, из-за чего iOS тут же закрывает окно. Держим запрет выключенным.
      try {
        Object.defineProperty(HTMLVideoElement.prototype, 'disablePictureInPicture', {
          configurable: true, get() { return false; }, set() {},
        });
        const setAttributeForPip = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (name, value) {
          if (String(name).toLowerCase() === 'disablepictureinpicture') return;
          return setAttributeForPip.call(this, name, value);
        };
        new MutationObserver((records) => {
          for (const r of records) {
            if (r.target.hasAttribute && r.target.hasAttribute('disablepictureinpicture')) r.target.removeAttribute('disablepictureinpicture');
          }
        }).observe(document, { attributes: true, attributeFilter: ['disablepictureinpicture'], subtree: true });
      } catch (err) {}
      // Картинка в картинке: включить/выключить и сообщать приложению, когда меняется.
      document.addEventListener('webkitpresentationmodechanged', (e) => {
        try { window.webkit.messageHandlers.player.postMessage({ event: 'pip', mode: e.target.webkitPresentationMode }); } catch (err) {}
      }, true);
      window.addEventListener('message', (e) => {
        if (e.data && typeof e.data.vrPip === 'boolean') {
          const video = document.querySelector('video');
          if (!video) return;
          try {
            if (!e.data.vrPip) {
              video.webkitSetPresentationMode('inline');
            } else if (video.webkitPresentationMode !== 'picture-in-picture') {
              // Стандартный способ работает на айфоне; если нет — старый способ WebKit.
              const legacy = () => { try { video.webkitSetPresentationMode('picture-in-picture'); } catch (err) {} };
              if (video.requestPictureInPicture) video.requestPictureInPicture().catch(legacy);
              else legacy();
            }
          } catch (err) {}
          return;
        }
        if (e.data && typeof e.data.vrRate === 'number') {
          rate = Math.max(0.8, Math.min(1.2, e.data.vrRate));
          const video = document.querySelector('video');
          if (video && Math.abs(video.playbackRate - rate) > 0.001) video.playbackRate = rate;
        }
      });
      setInterval(() => {
        const video = document.querySelector('video');
        if (!video) return;
        if (rate !== 1 && Math.abs(video.playbackRate - rate) > 0.001) video.playbackRate = rate;
        try {
          window.webkit.messageHandlers.player.postMessage({
            event: 'tick', t: video.currentTime, paused: video.paused || video.readyState < 3,
            rate: video.playbackRate, at: Date.now(),
          });
        } catch (e) {}
      }, 500);
    })();
    """

    private static let alwaysVisibleScript = """
    (() => {
      try {
        Object.defineProperty(document, 'hidden', { get: () => false, configurable: true });
        Object.defineProperty(document, 'visibilityState', { get: () => 'visible', configurable: true });
        Object.defineProperty(document, 'webkitHidden', { get: () => false, configurable: true });
        for (const type of ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'blur', 'freeze']) {
          window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
          document.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
        }
        document.hasFocus = () => true;
      } catch (e) {}
    })();
    """

    /// Регулятор громкости внутри плеера youtube.com. Ставится до скриптов YouTube.
    ///
    /// YouTube сам пропускает звук ролика через Web Audio (выравнивание громкости),
    /// поэтому перехватываем подключение к динамикам (AudioDestinationNode) и вставляем
    /// перед ним свой GainNode. Если YouTube Web Audio не использует, подключаем
    /// <video> к своему регулятору сами.
    private static let volumeScript = """
    (() => {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      let volume = 1;
      const gains = new Set();
      const gainFor = new WeakMap();
      const analysers = new Map();
      const post = (m) => { try { window.webkit.messageHandlers.player.postMessage(m); } catch (e) {} };
      // iOS «прерывает» Web Audio при сворачивании — сразу будим, чтобы не было тишины.
      const keepAwake = (ctx) => ctx.addEventListener('statechange', () => {
        if (ctx.state !== 'running' && ctx.state !== 'closed') ctx.resume().catch(() => {});
      });
      const originalConnect = AudioNode.prototype.connect;
      AudioNode.prototype.connect = function (destination, ...rest) {
        if (destination instanceof AudioDestinationNode && !gains.has(this)) {
          const ctx = destination.context;
          let gain = gainFor.get(ctx);
          if (!gain) {
            gain = ctx.createGain();
            gain.gain.value = volume;
            const analyser = ctx.createAnalyser();
            analysers.set(gain, analyser);
            originalConnect.call(gain, analyser);
            originalConnect.call(analyser, destination);
            gainFor.set(ctx, gain);
            gains.add(gain);
            keepAwake(ctx);
            post({ event: 'volumeHook', ok: true, via: 'youtube' });
          }
          return originalConnect.call(this, gain, ...rest);
        }
        return originalConnect.call(this, destination, ...rest);
      };
      // Если YouTube не подключил <video> к Web Audio, подключаем сами.
      let ownCtx = null;
      let keepAliveStarted = false;
      const hooked = new WeakSet();
      setInterval(async () => {
        for (const video of document.querySelectorAll('video')) {
          if (hooked.has(video)) continue;
          hooked.add(video);
          try {
            if (!ownCtx) { ownCtx = new AudioContext(); keepAwake(ownCtx); }
            if (ownCtx.state !== 'running') await ownCtx.resume();
            if (ownCtx.state !== 'running') { hooked.delete(video); continue; }
            if (!keepAliveStarted) {
              // Неслышный сигнал (-90 дБ, 20 Гц) мимо регулятора громкости: плеер всегда
              // «звучит», и iOS не усыпляет его в фоне между треками и на паузе — иначе
              // трек, включённый другом, пока ты в игре, не начинается до возврата в приложение.
              keepAliveStarted = true;
              const osc = ownCtx.createOscillator();
              const quiet = ownCtx.createGain();
              osc.frequency.value = 20;
              quiet.gain.value = 0.00003;
              originalConnect.call(osc, quiet);
              originalConnect.call(quiet, ownCtx.destination);
              osc.start();
              post({ event: 'keepAlive', state: ownCtx.state, via: 'youtube' });
            }
            ownCtx.createMediaElementSource(video).connect(ownCtx.destination); // пройдёт через перехват
            post({ event: 'volumeHook', ok: true, via: 'own' });
          } catch (e) {
            // InvalidStateError: YouTube уже подключил видео к своему Web Audio — перехват это покрывает.
          }
        }
      }, 700);
      window.addEventListener('message', (e) => {
        if (e.data && typeof e.data.vrVolume === 'number') {
          volume = Math.max(0, Math.min(1, e.data.vrVolume));
          for (const gain of gains) gain.gain.value = volume;
        }
      });
      setInterval(() => {
        const video = document.querySelector('video');
        const src = video ? String(video.currentSrc || video.src || '').slice(0, 30) : 'нет video';
        const el = video ? { rs: video.readyState, ns: video.networkState, err: video.error?.code ?? 0, paused: video.paused } : {};
        for (const gain of gains) {
          const analyser = analysers.get(gain);
          let rms = -1;
          if (analyser) {
            const data = new Float32Array(analyser.fftSize);
            analyser.getFloatTimeDomainData(data);
            let sum = 0; for (const x of data) sum += x * x;
            rms = Math.round(Math.sqrt(sum / data.length) * 10000) / 10000;
          }
          post({ event: 'level', gain: gain.gain.value, ctx: gain.context.state, rms, src, ...el });
          if (gain.context.state !== 'running') gain.context.resume().catch(() => {});
        }
      }, 4000);
    })();
    """

    /// Включает ролик по id (11 символов из ссылки YouTube).
    func load(videoId: String, startSeconds: Double = 0) {
        guard videoId.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return }
        run("vr.load('\(videoId)', \(startSeconds))")
    }

    func play() { run("vr.play()") }
    func mute() { run("vr.mute()") }
    func pause() { run("vr.pause()") }
    func seek(to seconds: Double) { run("vr.seek(\(seconds))") }
    /// Громкость 0…1 (через свой регулятор внутри плеера, см. volumeScript).
    func setVolume(_ volume: Double) { run("vr.setVolume(\(volume))") }
    /// Название и обложка в острове и на экране блокировки.
    func setNowPlaying(title: String, artist: String, artwork: String?) {
        var info: [String: String] = ["title": title, "artist": artist, "album": "VoiceRoom"]
        info["artwork"] = artwork
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else { return }
        run("vr.nowPlaying(\(json))")
    }

    /// Системная картинка в картинке (только плеер картинки).
    func setPictureInPicture(_ on: Bool) { run("vr.pip(\(on))") }

    /// Скорость картинки (0.8…1.2), чтобы догнать звук без перемотки.
    func setRate(_ rate: Double) { run("vr.setRate(\(rate))") }

    /// Состояние плеера: state, time, duration, title, hidden.
    func status() async -> [String: Any]? {
        guard isReady else { return nil }
        return try? await webView.evaluateJavaScript("vr.status()") as? [String: Any]
    }

    private func run(_ script: String) {
        guard isReady else {
            pending.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let event = message.body as? [String: Any] ?? [:]
        if event["event"] as? String == "ready", !isReady {
            isReady = true
            pending.forEach { webView.evaluateJavaScript($0, completionHandler: nil) }
            pending = []
        }
        onEvent?(event)
    }
}

/// Без этой прослойки WKUserContentController держит плеер вечно.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// WKWebView, который не отступает от краёв экрана: на iPhone Duo без этого
/// страница сжимается и не заходит под правую полосу.
final class EdgeToEdgeWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

struct YouTubePlayerView: UIViewRepresentable {
    let player: YouTubePlayer

    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
