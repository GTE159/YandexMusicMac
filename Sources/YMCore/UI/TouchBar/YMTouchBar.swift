import SwiftUI
import AppKit
import Observation

// MARK: - Touch Bar Item Identifiers

private extension NSTouchBar.CustomizationIdentifier {
    static let ymMainTouchBar = NSTouchBar.CustomizationIdentifier("com.yandexmusic.mac.touchbar.main")
}

private extension NSTouchBarItem.Identifier {
    static let nowPlayingPill = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.nowPlaying")
    static let likeButton = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.like")
    static let waveActionButton = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.waveAction")
    static let dislikeButton = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.dislike")
    static let transportCluster = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.transport")
    static let scrubber = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.scrubber")
    static let shuffleButton = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.shuffle")
    static let lyricsButton = NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.lyrics")
}

// MARK: - Native AppKit Touch Bar Controller

/// Native AppKit Touch Bar controller attached directly to `NSApplication`, `AppDelegate`, `NSWindow`,
/// and active `NSTextView` field editors so player controls remain present across every screen
/// (including non-search screens and while typing in search) whenever `flow~` is in the foreground.
@MainActor
public final class YMTouchBarController: NSObject, NSTouchBarDelegate {
    public static let shared = YMTouchBarController()

    public private(set) lazy var touchBar: NSTouchBar = makeMainTouchBar()

    // Cached custom views for flicker-free incremental updates
    private let nowPlayingView = YMTouchBarNowPlayingView()
    private let likeView = YMTouchBarPillButtonView(width: 36, symbolName: "heart", pointSize: 13)
    private let waveActionView = YMTouchBarPillButtonView(width: 36, symbolName: "waveform.path.ecg", pointSize: 13)
    private let dislikeView = YMTouchBarPillButtonView(width: 36, symbolName: "hand.thumbsdown.fill", pointSize: 12.5)
    private let transportView = YMTouchBarTransportClusterView()
    private let scrubberView = YMTouchBarProgressScrubberView()
    private let shuffleView = YMTouchBarPillButtonView(width: 36, symbolName: "shuffle", pointSize: 12.5)
    private let lyricsView = YMTouchBarPillButtonView(width: 36, symbolName: "quote.bubble", pointSize: 12.5)

    private var isInstalled = false
    private var notificationObservers: [any NSObjectProtocol] = []
    private var hasPendingRefresh = false
    private var artworkTask: Task<Void, Never>?
    private var loadedArtworkUri: String?
    private var lastLoadedArtworkImage: NSImage?
    private var waveFlashResetTask: Task<Void, Never>?
    private var isWaveFlameFlashing = false

    private override init() {
        super.init()
        configureViewActions()
    }

    public func install() {
        guard !isInstalled else {
            attachToApplicationAndWindows()
            return
        }
        isInstalled = true

        NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        attachToApplicationAndWindows()
        installSystemObservers()
        scheduleObservationTracking()
        refreshAll(forceMetadata: true)
    }

    public func attachToWindow(_ window: NSWindow?) {
        guard let window, !(window is NSPanel) else { return }
        if window.touchBar !== touchBar {
            window.touchBar = touchBar
        }
        if NSApplication.shared.touchBar !== touchBar {
            NSApplication.shared.touchBar = touchBar
        }
    }

    private func attachToApplicationAndWindows() {
        if NSApplication.shared.touchBar !== touchBar {
            NSApplication.shared.touchBar = touchBar
        }
        for window in NSApp.windows where !(window is NSPanel) {
            if WindowState.shared.isValidAppWindow(window) || window.isKeyWindow || window.isMainWindow {
                if window.touchBar !== touchBar {
                    window.touchBar = touchBar
                }
            }
        }
    }

    private func installSystemObservers() {
        let center = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let keyObs = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToApplicationAndWindows()
            }
        }
        let mainObs = center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToApplicationAndWindows()
            }
        }
        let activeObs = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToApplicationAndWindows()
                self?.refreshAll(forceMetadata: false)
            }
        }
        let textBeginObs = center.addObserver(forName: NSText.didBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      let textView = (NSApp.keyWindow?.firstResponder as? NSTextView)
                        ?? (NSApp.mainWindow?.firstResponder as? NSTextView) else {
                    return
                }
                // Keep player Touch Bar intact even while typing in Search / Settings fields
                if textView.touchBar !== self.touchBar {
                    textView.touchBar = self.touchBar
                }
            }
        }
        let spaceObs = workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.attachToApplicationAndWindows()
            }
        }

        notificationObservers = [keyObs, mainObs, activeObs, textBeginObs, spaceObs]
    }

    private func makeMainTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = .ymMainTouchBar
        bar.defaultItemIdentifiers = [
            .nowPlayingPill,
            .likeButton,
            .waveActionButton,
            .flexibleSpace,
            .transportCluster,
            .scrubber,
            .flexibleSpace,
            .lyricsButton,
            .shuffleButton
        ]
        bar.customizationAllowedItemIdentifiers = [
            .nowPlayingPill,
            .likeButton,
            .waveActionButton,
            .dislikeButton,
            .transportCluster,
            .scrubber,
            .lyricsButton,
            .shuffleButton,
            .fixedSpaceSmall,
            .fixedSpaceLarge,
            .flexibleSpace
        ]
        return bar
    }

    // MARK: - NSTouchBarDelegate

    public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let isLiveBar = (touchBar === self.touchBar)
        let snapshot = makeVisualSnapshot()

        switch identifier {
        case .nowPlayingPill:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? nowPlayingView : YMTouchBarNowPlayingView()
            apply(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Сейчас играет"
            item.visibilityPriority = .high
            return item

        case .likeButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? likeView : YMTouchBarPillButtonView(width: 36, symbolName: "heart", pointSize: 13)
            applyLike(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Мне нравится"
            item.visibilityPriority = .normal
            return item

        case .waveActionButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? waveActionView : YMTouchBarPillButtonView(width: 36, symbolName: "waveform.path.ecg", pointSize: 13)
            applyWave(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Моя волна"
            item.visibilityPriority = .normal
            return item

        case .dislikeButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? dislikeView : YMTouchBarPillButtonView(width: 36, symbolName: "hand.thumbsdown.fill", pointSize: 12.5)
            applyDislike(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Меньше таких"
            item.visibilityPriority = .low
            return item

        case .transportCluster:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? transportView : YMTouchBarTransportClusterView()
            applyTransport(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Управление воспроизведением"
            item.visibilityPriority = .high
            return item

        case .scrubber:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? scrubberView : YMTouchBarProgressScrubberView()
            applyScrubber(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Прогресс трека"
            item.visibilityPriority = .normal
            return item

        case .shuffleButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? shuffleView : YMTouchBarPillButtonView(width: 36, symbolName: "shuffle", pointSize: 12.5)
            applyShuffle(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Перемешать"
            item.visibilityPriority = .low
            return item

        case .lyricsButton:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = isLiveBar ? lyricsView : YMTouchBarPillButtonView(width: 36, symbolName: "quote.bubble", pointSize: 12.5)
            applyLyrics(snapshot, to: view)
            item.view = view
            item.customizationLabel = "Текст песни"
            item.visibilityPriority = .normal
            return item

        default:
            return nil
        }
    }

    // MARK: - Actions & Wiring

    private func configureViewActions() {
        nowPlayingView.onTap = { [weak self] in
            self?.handleNowPlayingTap()
        }

        transportView.onPrevious = {
            AudioPlayerEngine.shared.previous()
        }
        transportView.onPlayPause = {
            let engine = AudioPlayerEngine.shared
            if engine.currentTrack != nil {
                engine.togglePlayPause()
            } else {
                WaveSessionController.shared.startWave(
                    context: engine.activeWaveContext,
                    vibe: engine.activeWaveVibe
                )
            }
        }
        transportView.onNext = {
            AudioPlayerEngine.shared.next()
        }

        likeView.onTap = {
            guard let track = AudioPlayerEngine.shared.currentTrack else { return }
            Task { @MainActor in
                await LikesService.shared.toggleLike(track: track)
            }
        }

        waveActionView.onTap = { [weak self] in
            let engine = AudioPlayerEngine.shared
            if engine.isWaveMode && engine.currentTrack != nil {
                engine.applyWaveTuning(.moreLikeThis)
                self?.flashWaveFlame()
            } else if let track = engine.currentTrack {
                engine.startWave(forTrack: track)
            } else {
                WaveSessionController.shared.startWave(
                    context: engine.activeWaveContext,
                    vibe: engine.activeWaveVibe
                )
            }
        }

        dislikeView.onTap = {
            let engine = AudioPlayerEngine.shared
            guard engine.isWaveMode, engine.currentTrack != nil else { return }
            engine.applyWaveTuning(.lessLikeThis)
        }

        shuffleView.onTap = {
            AudioPlayerEngine.shared.toggleShuffle()
        }

        lyricsView.onTap = {
            let coordinator = NavigationCoordinator.shared
            guard let track = AudioPlayerEngine.shared.currentTrack else { return }
            if coordinator.isLyricsPresented {
                coordinator.isLyricsPresented = false
                coordinator.lyricsTrack = nil
            } else {
                coordinator.showLyrics(for: track)
            }
        }

        scrubberView.onSeekCommitted = { seconds in
            AudioPlayerEngine.shared.seek(to: seconds)
        }
    }

    private func handleNowPlayingTap() {
        let engine = AudioPlayerEngine.shared
        if engine.currentTrack == nil {
            WaveSessionController.shared.startWave(
                context: engine.activeWaveContext,
                vibe: engine.activeWaveVibe
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        if let mainWin = NSApp.windows.first(where: { !($0 is NSPanel) && WindowState.shared.isValidAppWindow($0) }) {
            mainWin.makeKeyAndOrderFront(nil)
        }
    }

    private func flashWaveFlame() {
        isWaveFlameFlashing = true
        refreshAll(forceMetadata: false)
        waveFlashResetTask?.cancel()
        waveFlashResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            self.isWaveFlameFlashing = false
            self.refreshAll(forceMetadata: false)
        }
    }

    // MARK: - Observation & Coalesced Refresh

    private func scheduleObservationTracking() {
        let engine = AudioPlayerEngine.shared
        let likes = LikesService.shared
        let theme = YMThemeManager.shared
        let coordinator = NavigationCoordinator.shared

        withObservationTracking {
            _ = engine.currentTrack
            _ = engine.isPlaying
            _ = engine.isWaveMode
            _ = engine.isShuffleEnabled
            _ = engine.isExclusiveHogActive
            _ = engine.progressTracker.currentTime
            _ = engine.progressTracker.duration
            _ = likes.likedTrackIds
            _ = theme.currentTheme
            _ = theme.resolvedPalette
            _ = coordinator.isLyricsPresented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleCoalescedRefresh()
            }
        }
    }

    private func scheduleCoalescedRefresh() {
        guard !hasPendingRefresh else { return }
        hasPendingRefresh = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hasPendingRefresh = false
            self.scheduleObservationTracking()
            self.refreshAll(forceMetadata: false)
        }
    }

    private struct TouchBarSnapshot {
        let title: String
        let subtitle: String
        let subtitleColor: NSColor
        let accentColor: NSColor
        let artwork: NSImage?
        let hasTrack: Bool
        let isPlaying: Bool
        let isWaveMode: Bool
        let isWaveFlameFlashing: Bool
        let isLiked: Bool
        let canShuffle: Bool
        let isShuffleEnabled: Bool
        let isLyricsOpen: Bool
        let currentTime: Double
        let duration: Double
    }

    private func makeVisualSnapshot() -> TouchBarSnapshot {
        let engine = AudioPlayerEngine.shared
        let track = engine.currentTrack
        let isWaveMode = engine.isWaveMode
        let palette = YMThemeManager.shared.resolvedPalette
        let accentColor = palette.isLight ? NSColor(YMTheme.accentFill) : NSColor(palette.accent)
        let currentTime = engine.progressTracker.currentTime
        let duration = engine.progressTracker.duration > 0
            ? engine.progressTracker.duration
            : (Double(track?.durationMs ?? 0) / 1000.0)

        let titleText = track?.displayTitle ?? "flow~"
        let subtitleText: String
        var subtitleColor = NSColor(white: 1.0, alpha: 0.65)
        if let track {
            if engine.isExclusiveHogActive {
                subtitleText = "\(track.artistsString) · Bit-Perfect"
                subtitleColor = accentColor
            } else if isWaveMode {
                subtitleText = "\(track.artistsString) · Моя волна"
                subtitleColor = accentColor.withAlphaComponent(0.92)
            } else {
                subtitleText = track.artistsString
            }
        } else {
            subtitleText = "Запустить Мою волну"
            subtitleColor = accentColor.withAlphaComponent(0.9)
        }

        let coverUri = track?.effectiveCoverUri
        let cachedArtwork = coverUri.flatMap {
            $0 == loadedArtworkUri ? lastLoadedArtworkImage : ImagePipeline.shared.cachedImage(for: $0, size: .small)
        }

        return TouchBarSnapshot(
            title: titleText,
            subtitle: subtitleText,
            subtitleColor: subtitleColor,
            accentColor: accentColor,
            artwork: cachedArtwork,
            hasTrack: track != nil,
            isPlaying: engine.isPlaying,
            isWaveMode: isWaveMode,
            isWaveFlameFlashing: isWaveFlameFlashing,
            isLiked: track.map { LikesService.shared.isLiked(trackId: $0.id) } ?? false,
            canShuffle: !isWaveMode && engine.queue.count > 1,
            isShuffleEnabled: !isWaveMode && engine.isShuffleEnabled,
            isLyricsOpen: NavigationCoordinator.shared.isLyricsPresented,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func refreshAll(forceMetadata: Bool) {
        let track = AudioPlayerEngine.shared.currentTrack
        let coverUri = track?.effectiveCoverUri
        if forceMetadata || coverUri != loadedArtworkUri {
            loadedArtworkUri = coverUri
            artworkTask?.cancel()
            artworkTask = nil

            if let coverUri, !coverUri.isEmpty {
                if let cached = ImagePipeline.shared.cachedImage(for: coverUri, size: .small) {
                    lastLoadedArtworkImage = cached
                } else {
                    lastLoadedArtworkImage = nil
                    let targetUri = coverUri
                    artworkTask = Task { @MainActor [weak self] in
                        let img = await ImagePipeline.shared.image(for: targetUri, size: .small)
                        guard !Task.isCancelled, let self, self.loadedArtworkUri == targetUri else { return }
                        self.lastLoadedArtworkImage = img
                        self.nowPlayingView.updateArtworkOnly(img)
                    }
                }
            } else {
                lastLoadedArtworkImage = nil
            }
        }

        let snapshot = makeVisualSnapshot()
        apply(snapshot, to: nowPlayingView)
        applyTransport(snapshot, to: transportView)
        applyScrubber(snapshot, to: scrubberView)
        applyLike(snapshot, to: likeView)
        applyWave(snapshot, to: waveActionView)
        applyDislike(snapshot, to: dislikeView)
        applyShuffle(snapshot, to: shuffleView)
        applyLyrics(snapshot, to: lyricsView)
    }

    private func apply(_ s: TouchBarSnapshot, to view: YMTouchBarNowPlayingView) {
        view.update(
            title: s.title,
            subtitle: s.subtitle,
            subtitleColor: s.subtitleColor,
            artwork: s.artwork,
            accentColor: s.accentColor,
            isWaveActive: s.isWaveMode && s.hasTrack
        )
    }

    private func applyTransport(_ s: TouchBarSnapshot, to view: YMTouchBarTransportClusterView) {
        view.update(hasTrack: s.hasTrack, isPlaying: s.isPlaying, accentColor: s.accentColor)
    }

    private func applyScrubber(_ s: TouchBarSnapshot, to view: YMTouchBarProgressScrubberView) {
        view.update(currentTime: s.currentTime, duration: s.duration, hasTrack: s.hasTrack, accentColor: s.accentColor)
    }

    private func applyLike(_ s: TouchBarSnapshot, to view: YMTouchBarPillButtonView) {
        let heartRed = NSColor(YMTheme.heartRed)
        view.update(
            symbolName: s.isLiked ? "heart.fill" : "heart",
            tint: s.isLiked ? heartRed : NSColor(white: 1.0, alpha: 0.85),
            fillColor: s.isLiked ? heartRed.withAlphaComponent(0.22) : NSColor(white: 1.0, alpha: 0.10),
            borderColor: s.isLiked ? heartRed.withAlphaComponent(0.55) : NSColor(white: 1.0, alpha: 0.14),
            isEnabled: s.hasTrack
        )
    }

    private func applyWave(_ s: TouchBarSnapshot, to view: YMTouchBarPillButtonView) {
        let waveSymbol = (s.isWaveMode && s.hasTrack) ? "flame.fill" : "waveform.path.ecg"
        let waveActive = s.isWaveMode || s.isWaveFlameFlashing
        let waveTint = s.isWaveFlameFlashing ? NSColor.systemOrange : (waveActive ? s.accentColor : NSColor(white: 1.0, alpha: 0.85))
        view.update(
            symbolName: waveSymbol,
            tint: waveTint,
            fillColor: waveActive ? s.accentColor.withAlphaComponent(0.20) : NSColor(white: 1.0, alpha: 0.10),
            borderColor: waveActive ? s.accentColor.withAlphaComponent(0.50) : NSColor(white: 1.0, alpha: 0.14),
            isEnabled: true
        )
    }

    private func applyDislike(_ s: TouchBarSnapshot, to view: YMTouchBarPillButtonView) {
        let active = s.isWaveMode && s.hasTrack
        view.update(
            symbolName: "hand.thumbsdown.fill",
            tint: active ? NSColor(white: 1.0, alpha: 0.85) : NSColor(white: 1.0, alpha: 0.32),
            fillColor: NSColor(white: 1.0, alpha: 0.10),
            borderColor: NSColor(white: 1.0, alpha: 0.14),
            isEnabled: active
        )
    }

    private func applyShuffle(_ s: TouchBarSnapshot, to view: YMTouchBarPillButtonView) {
        view.update(
            symbolName: "shuffle",
            tint: s.isShuffleEnabled ? s.accentColor : NSColor(white: 1.0, alpha: s.canShuffle ? 0.85 : 0.35),
            fillColor: s.isShuffleEnabled ? s.accentColor.withAlphaComponent(0.20) : NSColor(white: 1.0, alpha: 0.10),
            borderColor: s.isShuffleEnabled ? s.accentColor.withAlphaComponent(0.45) : NSColor(white: 1.0, alpha: 0.14),
            isEnabled: s.canShuffle
        )
    }

    private func applyLyrics(_ s: TouchBarSnapshot, to view: YMTouchBarPillButtonView) {
        view.update(
            symbolName: s.isLyricsOpen ? "quote.bubble.fill" : "quote.bubble",
            tint: s.isLyricsOpen ? s.accentColor : NSColor(white: 1.0, alpha: s.hasTrack ? 0.85 : 0.35),
            fillColor: s.isLyricsOpen ? s.accentColor.withAlphaComponent(0.20) : NSColor(white: 1.0, alpha: 0.10),
            borderColor: s.isLyricsOpen ? s.accentColor.withAlphaComponent(0.45) : NSColor(white: 1.0, alpha: 0.14),
            isEnabled: s.hasTrack
        )
    }
}

// MARK: - SwiftUI Entrypoint Compatibility

public struct YMPlaybackTouchBar: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .onAppear {
                YMTouchBarController.shared.install()
            }
    }
}

public extension View {
    func ymTouchBar() -> some View {
        modifier(YMPlaybackTouchBar())
    }
}

// MARK: - Custom Modern Touch Bar Views

@MainActor
private enum YMTouchBarFeedbackAnimator {
    static func makeHighlightLayer(cornerRadius: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.white.cgColor
        layer.opacity = 0
        return layer
    }

    static func pulseScale(
        on view: NSView,
        pressedScale: CGFloat = 0.88,
        overshootScale: CGFloat = 1.035,
        xShift: CGFloat = 0,
        duration: CFTimeInterval = 0.20
    ) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }

        let size = view.bounds.size
        let identity = CATransform3DIdentity
        let down = centeredTransform(scale: pressedScale, xOffset: xShift, size: size)
        let over = centeredTransform(scale: overshootScale, xOffset: -xShift * 0.25, size: size)

        let anim = CAKeyframeAnimation(keyPath: "transform")
        anim.values = [
            NSValue(caTransform3D: identity),
            NSValue(caTransform3D: down),
            NSValue(caTransform3D: over),
            NSValue(caTransform3D: identity)
        ]
        anim.keyTimes = [0.0, 0.22, 0.64, 1.0]
        anim.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0),
            CAMediaTimingFunction(controlPoints: 0.25, 0.8, 0.3, 1.0),
            CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
        ]
        anim.duration = duration
        anim.isRemovedOnCompletion = true
        layer.add(anim, forKey: "ym.tb.scale")
    }

    static func flashOverlay(_ overlayLayer: CALayer, peakOpacity: Float = 0.25, duration: CFTimeInterval = 0.22) {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [Float(0.0), peakOpacity, Float(0.0)]
        anim.keyTimes = [0.0, 0.20, 1.0]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        anim.duration = duration
        anim.isRemovedOnCompletion = true
        overlayLayer.add(anim, forKey: "ym.tb.flash")
    }

    private static func centeredTransform(scale: CGFloat, xOffset: CGFloat, size: CGSize) -> CATransform3D {
        guard size.width > 0, size.height > 0 else {
            return CATransform3DMakeScale(scale, scale, 1)
        }
        let cx = size.width * 0.5
        let cy = size.height * 0.5
        var t = CATransform3DMakeTranslation(cx * (1 - scale) + xOffset, cy * (1 - scale), 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return t
    }
}

@MainActor
private final class YMTouchBarPillButtonView: NSView {
    var onTap: (() -> Void)?

    private let backgroundLayer = CALayer()
    private let highlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 7)
    private let stackView = NSStackView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")

    private var isInteractiveEnabled = true
    private var currentSymbolName: String = ""

    init(width: CGFloat, symbolName: String, pointSize: CGFloat) {
        self.currentSymbolName = symbolName
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30)
        ])

        backgroundLayer.cornerRadius = 7
        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.borderWidth = 0.75
        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(highlightLayer)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            iconView.image = img
        }
        iconView.contentTintColor = .white

        titleLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClicked(_:)))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        highlightLayer.frame = bounds
        CATransaction.commit()
    }

    func update(
        symbolName: String,
        titleText: String? = nil,
        tint: NSColor,
        fillColor: NSColor,
        borderColor: NSColor,
        isEnabled: Bool
    ) {
        if currentSymbolName != symbolName {
            currentSymbolName = symbolName
            iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        iconView.contentTintColor = tint

        if let titleText, !titleText.isEmpty {
            titleLabel.stringValue = titleText
            titleLabel.textColor = tint
            titleLabel.isHidden = false
        } else {
            titleLabel.isHidden = true
        }

        isInteractiveEnabled = isEnabled
        alphaValue = isEnabled ? 1.0 : 0.45

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.backgroundColor = fillColor.cgColor
        backgroundLayer.borderColor = borderColor.cgColor
        CATransaction.commit()
    }

    @objc private func handleClicked(_ recognizer: NSClickGestureRecognizer) {
        guard isInteractiveEnabled else { return }
        YMTouchBarFeedbackAnimator.pulseScale(on: self)
        YMTouchBarFeedbackAnimator.flashOverlay(highlightLayer, peakOpacity: 0.26)
        onTap?()
    }
}

@MainActor
private final class YMTouchBarNowPlayingView: NSView {
    var onTap: (() -> Void)?

    private let backgroundLayer = CALayer()
    private let highlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 7)
    private let coverContainer = NSView()
    private let coverImageView = NSImageView()
    private let placeholderIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "flow~")
    private let subtitleLabel = NSTextField(labelWithString: "Запустить Мою волну")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 194, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let minW = widthAnchor.constraint(greaterThanOrEqualToConstant: 158)
        let idealW = widthAnchor.constraint(equalToConstant: 194)
        idealW.priority = .defaultHigh
        let maxW = widthAnchor.constraint(lessThanOrEqualToConstant: 232)
        NSLayoutConstraint.activate([
            minW,
            idealW,
            maxW,
            heightAnchor.constraint(equalToConstant: 30)
        ])

        backgroundLayer.cornerRadius = 7
        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.borderWidth = 0.75
        backgroundLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.09).cgColor
        backgroundLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(highlightLayer)

        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.wantsLayer = true
        coverContainer.layer?.cornerRadius = 4.5
        coverContainer.layer?.cornerCurve = .continuous
        coverContainer.layer?.masksToBounds = true
        coverContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.imageScaling = .scaleAxesIndependently

        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false
        placeholderIcon.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        placeholderIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
        placeholderIcon.contentTintColor = .systemYellow

        coverContainer.addSubview(placeholderIcon)
        coverContainer.addSubview(coverImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        subtitleLabel.textColor = NSColor(white: 1.0, alpha: 0.65)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(coverContainer)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            coverContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            coverContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            coverContainer.widthAnchor.constraint(equalToConstant: 22),
            coverContainer.heightAnchor.constraint(equalToConstant: 22),

            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),

            placeholderIcon.centerXAnchor.constraint(equalTo: coverContainer.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: coverContainer.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: coverContainer.trailingAnchor, constant: 7),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClicked))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        highlightLayer.frame = bounds
        CATransaction.commit()
    }

    func update(
        title: String,
        subtitle: String,
        subtitleColor: NSColor,
        artwork: NSImage?,
        accentColor: NSColor,
        isWaveActive: Bool
    ) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = subtitleColor
        placeholderIcon.contentTintColor = accentColor
        updateArtworkOnly(artwork)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isWaveActive {
            backgroundLayer.backgroundColor = accentColor.withAlphaComponent(0.11).cgColor
            backgroundLayer.borderColor = accentColor.withAlphaComponent(0.32).cgColor
        } else {
            backgroundLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.09).cgColor
            backgroundLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        }
        CATransaction.commit()
    }

    func updateArtworkOnly(_ image: NSImage?) {
        coverImageView.image = image
        coverImageView.isHidden = (image == nil)
        placeholderIcon.isHidden = (image != nil)
    }

    @objc private func handleClicked() {
        YMTouchBarFeedbackAnimator.pulseScale(on: self, pressedScale: 0.965, overshootScale: 1.01, duration: 0.19)
        YMTouchBarFeedbackAnimator.flashOverlay(highlightLayer, peakOpacity: 0.16)
        onTap?()
    }
}

private final class YMTouchBarNonVibrantView: NSView {
    override var allowsVibrancy: Bool { false }
}

private final class YMTouchBarOpaqueImageView: NSImageView {
    override var allowsVibrancy: Bool { false }
}

@MainActor
private final class YMTouchBarTransportClusterView: NSView {
    var onPrevious: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    private let outerLayer = CALayer()
    private let prevZone = NSView()
    private let playDisc = YMTouchBarNonVibrantView()
    private let nextZone = NSView()

    private let prevHighlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 5.5)
    private let playHighlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 6)
    private let nextHighlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 5.5)

    private let prevIcon = NSImageView()
    private let playIcon = YMTouchBarOpaqueImageView()
    private let nextIcon = NSImageView()

    private static let crispPlayImage = makeCrispBlackSymbol("play.fill")
    private static let crispPauseImage = makeCrispBlackSymbol("pause.fill")

    private var currentPlaySymbol = "play.fill"
    private var hasTrackState = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 120),
            heightAnchor.constraint(equalToConstant: 30)
        ])

        outerLayer.cornerRadius = 7.5
        outerLayer.cornerCurve = .continuous
        outerLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.09).cgColor
        outerLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        outerLayer.borderWidth = 0.75
        layer?.addSublayer(outerLayer)

        prevZone.translatesAutoresizingMaskIntoConstraints = false
        prevZone.wantsLayer = true
        prevZone.layer?.addSublayer(prevHighlightLayer)

        playDisc.translatesAutoresizingMaskIntoConstraints = false
        playDisc.wantsLayer = true
        playDisc.layer?.cornerRadius = 6
        playDisc.layer?.cornerCurve = .continuous
        playDisc.layer?.addSublayer(playHighlightLayer)

        nextZone.translatesAutoresizingMaskIntoConstraints = false
        nextZone.wantsLayer = true
        nextZone.layer?.addSublayer(nextHighlightLayer)

        prevIcon.translatesAutoresizingMaskIntoConstraints = false
        prevIcon.wantsLayer = true
        prevIcon.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Предыдущий")
        prevIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        prevIcon.contentTintColor = .white

        playIcon.translatesAutoresizingMaskIntoConstraints = false
        playIcon.imageScaling = .scaleProportionallyDown
        playIcon.image = Self.crispPlayImage

        nextIcon.translatesAutoresizingMaskIntoConstraints = false
        nextIcon.wantsLayer = true
        nextIcon.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Следующий")
        nextIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        nextIcon.contentTintColor = .white

        prevZone.addSubview(prevIcon)
        playDisc.addSubview(playIcon)
        nextZone.addSubview(nextIcon)

        addSubview(prevZone)
        addSubview(playDisc)
        addSubview(nextZone)

        NSLayoutConstraint.activate([
            prevZone.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            prevZone.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            prevZone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            prevZone.widthAnchor.constraint(equalToConstant: 35),

            playDisc.leadingAnchor.constraint(equalTo: prevZone.trailingAnchor, constant: 2),
            playDisc.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            playDisc.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            playDisc.widthAnchor.constraint(equalToConstant: 42),

            nextZone.leadingAnchor.constraint(equalTo: playDisc.trailingAnchor, constant: 2),
            nextZone.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            nextZone.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nextZone.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            prevIcon.centerXAnchor.constraint(equalTo: prevZone.centerXAnchor),
            prevIcon.centerYAnchor.constraint(equalTo: prevZone.centerYAnchor),
            playIcon.centerXAnchor.constraint(equalTo: playDisc.centerXAnchor),
            playIcon.centerYAnchor.constraint(equalTo: playDisc.centerYAnchor),
            nextIcon.centerXAnchor.constraint(equalTo: nextZone.centerXAnchor),
            nextIcon.centerYAnchor.constraint(equalTo: nextZone.centerYAnchor)
        ])

        prevZone.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handlePrev)))
        playDisc.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handlePlayPause)))
        nextZone.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleNext)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outerLayer.frame = bounds
        prevHighlightLayer.frame = prevZone.bounds
        playHighlightLayer.frame = playDisc.bounds
        nextHighlightLayer.frame = nextZone.bounds
        CATransaction.commit()
    }

    func update(hasTrack: Bool, isPlaying: Bool, accentColor: NSColor) {
        hasTrackState = hasTrack
        let symbol = isPlaying ? "pause.fill" : "play.fill"
        if currentPlaySymbol != symbol {
            currentPlaySymbol = symbol
            playIcon.image = isPlaying ? Self.crispPauseImage : Self.crispPlayImage
        }

        prevIcon.contentTintColor = hasTrack ? NSColor(white: 1.0, alpha: 0.90) : NSColor(white: 1.0, alpha: 0.30)
        nextIcon.contentTintColor = hasTrack ? NSColor(white: 1.0, alpha: 0.90) : NSColor(white: 1.0, alpha: 0.30)

        let idleGold = accentColor.blended(
            withFraction: 0.28,
            of: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        ) ?? accentColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playDisc.layer?.backgroundColor = hasTrack ? accentColor.cgColor : idleGold.cgColor
        CATransaction.commit()
    }

    /// Renders a non-template solid black symbol so Touch Bar vibrancy never dims it to gray.
    private static func makeCrispBlackSymbol(_ symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return nil
        }
        let targetSize = NSSize(width: ceil(base.size.width), height: ceil(base.size.height))
        let ink = NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1.0)
        let image = NSImage(size: targetSize, flipped: false) { rect in
            base.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func handlePrev() {
        guard hasTrackState else { return }
        YMTouchBarFeedbackAnimator.pulseScale(
            on: prevIcon,
            pressedScale: 0.84,
            overshootScale: 1.06,
            xShift: -2.2,
            duration: 0.19
        )
        YMTouchBarFeedbackAnimator.flashOverlay(prevHighlightLayer, peakOpacity: 0.24)
        onPrevious?()
    }

    @objc private func handlePlayPause() {
        YMTouchBarFeedbackAnimator.pulseScale(on: playDisc, pressedScale: 0.88, overshootScale: 1.035, duration: 0.20)
        YMTouchBarFeedbackAnimator.flashOverlay(playHighlightLayer, peakOpacity: 0.28)
        onPlayPause?()
    }

    @objc private func handleNext() {
        guard hasTrackState else { return }
        YMTouchBarFeedbackAnimator.pulseScale(
            on: nextIcon,
            pressedScale: 0.84,
            overshootScale: 1.06,
            xShift: 2.2,
            duration: 0.19
        )
        YMTouchBarFeedbackAnimator.flashOverlay(nextHighlightLayer, peakOpacity: 0.24)
        onNext?()
    }
}

@MainActor
private final class YMTouchBarProgressScrubberView: NSView {
    var onSeekCommitted: ((Double) -> Void)?

    private let backgroundLayer = CALayer()
    private let highlightLayer = YMTouchBarFeedbackAnimator.makeHighlightLayer(cornerRadius: 7)
    private let trackBgLayer = CALayer()
    private let trackFillLayer = CALayer()
    private let thumbLayer = CALayer()

    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let totalLabel = NSTextField(labelWithString: "0:00")

    private var durationSeconds: Double = 0
    private var currentSeconds: Double = 0
    private var hasTrack = false
    private var isDragging = false
    private var dragFraction: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 172, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let minW = widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        let idealW = widthAnchor.constraint(equalToConstant: 172)
        idealW.priority = .defaultHigh
        let maxW = widthAnchor.constraint(lessThanOrEqualToConstant: 228)
        NSLayoutConstraint.activate([
            minW,
            idealW,
            maxW,
            heightAnchor.constraint(equalToConstant: 30)
        ])

        backgroundLayer.cornerRadius = 7
        backgroundLayer.cornerCurve = .continuous
        backgroundLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        backgroundLayer.borderColor = NSColor(white: 1.0, alpha: 0.14).cgColor
        backgroundLayer.borderWidth = 0.75
        layer?.addSublayer(backgroundLayer)
        layer?.addSublayer(highlightLayer)

        trackBgLayer.cornerRadius = 2
        trackBgLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        layer?.addSublayer(trackBgLayer)

        trackFillLayer.cornerRadius = 2
        trackFillLayer.backgroundColor = NSColor.systemYellow.cgColor
        layer?.addSublayer(trackFillLayer)

        thumbLayer.cornerRadius = 4
        thumbLayer.backgroundColor = NSColor.white.cgColor
        thumbLayer.isHidden = true
        layer?.addSublayer(thumbLayer)

        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false
        elapsedLabel.font = timeFont
        elapsedLabel.textColor = NSColor(white: 1.0, alpha: 0.78)

        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        totalLabel.font = timeFont
        totalLabel.textColor = NSColor(white: 1.0, alpha: 0.50)

        addSubview(elapsedLabel)
        addSubview(totalLabel)

        NSLayoutConstraint.activate([
            elapsedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            elapsedLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            totalLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            totalLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        ])

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundLayer.frame = bounds
        highlightLayer.frame = bounds
        CATransaction.commit()
        layoutProgressBar()
    }

    func update(currentTime: Double, duration: Double, hasTrack: Bool, accentColor: NSColor) {
        self.hasTrack = hasTrack
        self.durationSeconds = max(0, duration)
        if !isDragging {
            self.currentSeconds = max(0, currentTime)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackFillLayer.backgroundColor = accentColor.cgColor
        alphaValue = hasTrack ? 1.0 : 0.45
        CATransaction.commit()

        updateTimeLabels()
        layoutProgressBar()
    }

    private func updateTimeLabels() {
        let shownSec = isDragging ? (dragFraction * durationSeconds) : currentSeconds
        elapsedLabel.stringValue = Self.formatTime(shownSec)
        totalLabel.stringValue = Self.formatTime(durationSeconds)
    }

    private func layoutProgressBar() {
        let horizontalInset: CGFloat = 8
        let barWidth = max(0, bounds.width - horizontalInset * 2)
        let barY: CGFloat = 7
        let barHeight: CGFloat = 4

        let fraction: Double
        if !hasTrack || durationSeconds <= 0 {
            fraction = 0
        } else if isDragging {
            fraction = max(0, min(1, dragFraction))
        } else {
            fraction = max(0, min(1, currentSeconds / durationSeconds))
        }

        let fillW = barWidth * CGFloat(fraction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackBgLayer.frame = CGRect(x: horizontalInset, y: barY, width: barWidth, height: barHeight)
        trackFillLayer.frame = CGRect(x: horizontalInset, y: barY, width: fillW, height: barHeight)
        thumbLayer.frame = CGRect(x: horizontalInset + fillW - 4, y: barY - 2, width: 8, height: 8)
        thumbLayer.isHidden = !isDragging
        CATransaction.commit()
    }

    private func fractionForPoint(_ point: CGPoint) -> Double {
        let horizontalInset: CGFloat = 8
        let usable = max(1, bounds.width - horizontalInset * 2)
        return max(0.0, min(1.0, Double((point.x - horizontalInset) / usable)))
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard hasTrack, durationSeconds > 0 else { return }
        YMTouchBarFeedbackAnimator.flashOverlay(highlightLayer, peakOpacity: 0.14, duration: 0.18)
        let frac = fractionForPoint(recognizer.location(in: self))
        let target = frac * durationSeconds
        currentSeconds = target
        updateTimeLabels()
        layoutProgressBar()
        onSeekCommitted?(target)
    }

    @objc private func handlePan(_ recognizer: NSPanGestureRecognizer) {
        guard hasTrack, durationSeconds > 0 else { return }
        let frac = fractionForPoint(recognizer.location(in: self))
        switch recognizer.state {
        case .began, .changed:
            isDragging = true
            dragFraction = frac
            updateTimeLabels()
            layoutProgressBar()
        case .ended, .cancelled:
            isDragging = false
            let target = frac * durationSeconds
            currentSeconds = target
            updateTimeLabels()
            layoutProgressBar()
            if recognizer.state == .ended {
                onSeekCommitted?(target)
            }
        default:
            break
        }
    }

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let totalSec = Int(seconds.rounded(.down))
        let mins = totalSec / 60
        let secs = totalSec % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
