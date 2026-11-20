import SwiftUI

/// Плавающее окно с картинкой в стиле системной «картинки в картинке»:
/// нажал — появились кнопки (через 3 секунды прячутся), тянешь за само видео —
/// окно прилипает к ближайшему углу, смахнул к краю — прячется за край,
/// оставляя язычок. Разворачивается на весь экран. Звук играет отдельный
/// невидимый плеер, здесь только картинка.
struct FloatingVideo: View {
    let video: YouTubePlayer
    let shared: RoomPlayer
    /// Сколько места сверху и снизу занято панелями комнаты (внутри безопасной зоны).
    var topInset: CGFloat
    var bottomInset: CGFloat
    let onClose: () -> Void

    @AppStorage("miniPlayerCorner") private var corner = Corner.bottomTrailing.rawValue
    @State private var expanded = false
    /// Окно спрятано за левый или правый край.
    @State private var stashed: HorizontalEdge?
    @State private var drag: CGSize = .zero
    @State private var controlsVisible = false
    @State private var hideControls: Task<Void, Never>?

    enum Corner: Int {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var isTop: Bool { self == .topLeading || self == .topTrailing }
        var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    }

    private static let margin: CGFloat = 12
    /// Сколько видно от спрятанного окна.
    private static let stashTab: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(area: geo.size, safe: geo.safeAreaInsets, expanded: expanded,
                                topInset: topInset, bottomInset: bottomInset)
            ZStack {
                if expanded {
                    Color.black
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
                card(layout)
                    .frame(width: layout.video.width, height: layout.video.height)
                    .position(position(in: layout))
            }
        }
        .statusBarHidden(expanded)
        .persistentSystemOverlays(expanded ? .hidden : .automatic)
        .onChange(of: shared.isInPictureInPicture) { _, inPiP in
            // Видео ушло в системную картинку в картинке — своё окно прячем к краю.
            withAnimation(.spring(duration: 0.35)) {
                if inPiP {
                    expanded = false
                    stashed = (Corner(rawValue: corner) ?? .bottomTrailing).isLeading ? .leading : .trailing
                } else {
                    stashed = nil
                }
            }
        }
    }

    // MARK: - Окно

    private func card(_ layout: Layout) -> some View {
        ZStack {
            YouTubePlayerView(player: video)
                // Все касания — нашим кнопкам и перетаскиванию, не плееру YouTube.
                .allowsHitTesting(false)
            if controlsVisible, stashed == nil {
                controls(layout)
                    .transition(.opacity)
            }
            if let stashed {
                stashHandle(stashed)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 14, style: .continuous))
        .overlay {
            if !expanded {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
        }
        .shadow(color: .black.opacity(expanded ? 0 : 0.3), radius: 16, y: 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if stashed != nil {
                withAnimation(.spring(duration: 0.35)) { stashed = nil }
                if shared.isInPictureInPicture { shared.stopPictureInPicture() }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
                scheduleHide()
            }
        }
        .gesture(dragGesture(layout), including: expanded ? .subviews : .all)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Видео")
    }

    private func controls(_ layout: Layout) -> some View {
        let big = layout.expanded
        let side: CGFloat = big ? 40 : 30
        return ZStack {
            Color.black.opacity(0.32)
            VStack(spacing: 0) {
                HStack(spacing: big ? 12 : 4) {
                    if big {
                        glassButton("arrow.down.right.and.arrow.up.left", size: side, label: "Свернуть") {
                            withAnimation(.spring(duration: 0.35)) { expanded = false }
                        }
                    } else {
                        glassButton("xmark", size: side, label: "Скрыть видео", action: onClose)
                    }
                    Spacer()
                    glassButton("pip.enter", size: side, label: "Картинка в картинке поверх других приложений") {
                        shared.startPictureInPicture()
                    }
                    if !big {
                        glassButton("arrow.up.left.and.arrow.down.right", size: side, label: "На весь экран") {
                            withAnimation(.spring(duration: 0.35)) { expanded = true }
                        }
                    } else {
                        glassButton("xmark", size: side, label: "Скрыть видео") {
                            expanded = false
                            onClose()
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: big ? 44 : 22) {
                    plainButton("gobackward.15", size: big ? 26 : 17, label: "Назад на 15 секунд у всех") {
                        if let position = shared.currentPosition { Task { await shared.seek(to: position - 15) } }
                    }
                    plainButton(shared.isPaused ? "play.fill" : "pause.fill", size: big ? 40 : 26,
                                label: shared.isPaused ? "Продолжить у всех" : "Пауза у всех") {
                        Task { await shared.togglePause() }
                    }
                    plainButton("forward.end.fill", size: big ? 26 : 17, label: "Следующий трек") {
                        Task { await shared.skip() }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    glassButton(shared.isMutedLocally ? "speaker.slash.fill" : "speaker.wave.2.fill", size: side,
                                tint: shared.isMutedLocally ? .red : .white,
                                label: shared.isMutedLocally ? "Включить музыку у себя" : "Выключить музыку у себя") {
                        shared.toggleLocalMute()
                    }
                }
            }
            .padding(big ? 16 : 6)
        }
    }

    private func stashHandle(_ edge: HorizontalEdge) -> some View {
        HStack(spacing: 0) {
            if edge == .trailing {
                handleStrip(chevron: "chevron.left")
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                handleStrip(chevron: "chevron.right")
            }
        }
    }

    private func handleStrip(chevron: String) -> some View {
        Image(systemName: chevron)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.stashTab)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
    }

    private func glassButton(_ systemImage: String, size: CGFloat, tint: Color = .white, label: String,
                             action: @escaping () -> Void) -> some View
    {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func plainButton(_ systemImage: String, size: CGFloat, label: String,
                             action: @escaping () -> Void) -> some View
    {
        Button {
            action()
            scheduleHide()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 1.7, height: size * 1.7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Кнопки прячутся сами через 3 секунды.
    private func scheduleHide() {
        hideControls?.cancel()
        hideControls = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    // MARK: - Перетаскивание

    private func dragGesture(_ layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                drag = value.translation
                if controlsVisible { withAnimation { controlsVisible = false } }
            }
            .onEnded { value in
                let start = position(in: layout, includingDrag: false)
                let end = CGPoint(x: start.x + value.predictedEndTranslation.width,
                                  y: start.y + value.predictedEndTranslation.height)
                let card = layout.card
                withAnimation(.spring(duration: 0.4)) {
                    // Смахнули за край — прячем, оставляя язычок.
                    if end.x < card.width * 0.15 {
                        stashed = .leading
                    } else if end.x > layout.area.width - card.width * 0.15 {
                        stashed = .trailing
                    } else {
                        stashed = nil
                    }
                    let top = end.y < layout.area.height / 2
                    let leading = stashed.map { $0 == .leading } ?? (end.x < layout.area.width / 2)
                    corner = (top ? (leading ? Corner.topLeading : .topTrailing)
                        : (leading ? Corner.bottomLeading : .bottomTrailing)).rawValue
                    drag = .zero
                }
            }
    }

    // MARK: - Размеры и углы

    private struct Layout {
        let area: CGSize
        let safe: EdgeInsets
        let expanded: Bool
        let topInset: CGFloat
        let bottomInset: CGFloat

        /// Весь экран, включая края за безопасной зоной.
        var full: CGSize {
            CGSize(width: area.width + safe.leading + safe.trailing,
                   height: area.height + safe.top + safe.bottom)
        }

        var video: CGSize {
            let width = expanded
                ? min(full.width, full.height * 16 / 9)
                : min(250, max(180, area.width * 0.52))
            return CGSize(width: width, height: width * 9 / 16)
        }

        var card: CGSize { video }
    }

    private func position(in layout: Layout, includingDrag: Bool = true) -> CGPoint {
        if layout.expanded {
            return CGPoint(x: layout.full.width / 2 - layout.safe.leading,
                           y: layout.full.height / 2 - layout.safe.top)
        }
        let card = layout.card
        let spot = Corner(rawValue: corner) ?? .bottomTrailing
        let y = spot.isTop
            ? layout.topInset + card.height / 2
            : layout.area.height - layout.bottomInset - card.height / 2
        var x = spot.isLeading
            ? Self.margin + card.width / 2
            : layout.area.width - Self.margin - card.width / 2
        if let stashed {
            x = stashed == .leading
                ? Self.stashTab - card.width / 2
                : layout.area.width - Self.stashTab + card.width / 2
        }
        guard includingDrag else { return CGPoint(x: x, y: y) }
        return CGPoint(x: x + drag.width, y: y + drag.height)
    }
}
