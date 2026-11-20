import SwiftUI
import WebKit

/// Мобильный YouTube внутри приложения: листаешь и ищешь как обычно, а когда
/// открываешь ролик, окно возвращается к списку и спрашивает, включить ли его
/// в комнате. Сам ролик здесь не играет — звук будет в общем плеере.
struct YouTubeBrowserView: View {
    enum Pick {
        case now, queue, wholeList
    }

    /// Ссылка на выбранный ролик и что с ним сделать.
    let onPick: (String, Pick) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var browser = YouTubeBrowser()

    var body: some View {
        NavigationStack {
            BrowserWebView(webView: browser.webView)
                // На iPhone Duo — и под правую полосу, на всю ширину.
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                .navigationTitle("YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            browser.webView.goBack()
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .disabled(!browser.canGoBack)
                        .accessibilityLabel("Назад")
                    }
                }
                .confirmationDialog("Включить это видео в комнате?",
                                    isPresented: pickedShown,
                                    titleVisibility: .visible)
                {
                    if let picked = browser.picked, picked.contains("list=") {
                        Button(picked.contains("list=RD") ? "Включить весь микс" : "Включить весь плейлист") {
                            pick(.wholeList)
                        }
                    }
                    Button("Включить сейчас") { pick(.now) }
                    Button("Добавить в очередь") { pick(.queue) }
                    Button("Отмена", role: .cancel) { browser.picked = nil }
                }
        }
    }

    private var pickedShown: Binding<Bool> {
        Binding(get: { browser.picked != nil }, set: { if !$0 { browser.picked = nil } })
    }

    private func pick(_ choice: Pick) {
        guard let url = browser.picked else { return }
        browser.picked = nil
        onPick(url, choice)
        dismiss()
    }
}

@Observable
@MainActor
final class YouTubeBrowser: NSObject {
    let webView: WKWebView
    /// Ролик, на который нажали (ждёт ответа «включить сейчас / в очередь»).
    var picked: String?
    private(set) var canGoBack = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        // Без звука: если ролик успеет начаться, его не будет слышно поверх общего плеера.
        controller.addUserScript(WKUserScript(source: """
        setInterval(() => document.querySelectorAll('video').forEach((v) => { v.muted = true; }), 300);
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = controller
        webView = EdgeToEdgeWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.urlChanged(webView) }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                Task { @MainActor in self?.canGoBack = webView.canGoBack }
            },
        ]
        webView.load(URLRequest(url: URL(string: "https://m.youtube.com")!))
    }

    private func urlChanged(_ webView: WKWebView) {
        guard picked == nil, let url = webView.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let isVideo = (components.path == "/watch" && components.queryItems?.contains { $0.name == "v" } == true)
            || components.path.hasPrefix("/shorts/")
        guard isVideo else { return }
        // Не даём ролику открыться здесь: возвращаемся к списку и спрашиваем.
        picked = url.absoluteString
        if webView.canGoBack { webView.goBack() } else { webView.stopLoading() }
    }
}

private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
