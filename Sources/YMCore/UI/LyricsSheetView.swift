import SwiftUI

/// Integrated side panel for synchronized karaoke lyrics and text,
/// featuring real-time LRC tracking, glowing brand yellow active line, tap-to-seek,
/// and a translucent glass gradient looking monolithic with the main window.
public struct LyricsSheetView: View {
    public let track: YMTrack?

    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var syncedLyrics: YMSyncedLyrics? = nil
    @UIState private var supplement: YMTrackSupplement? = nil
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    private let networkClient = YMNetworkClient.shared

    public init(track: YMTrack?) {
        self.track = track
    }

    private var currentTrack: YMTrack? {
        track ?? audioEngine.currentTrack
    }

    private var activeLineIndex: Int? {
        syncedLyrics?.activeLineIndex(for: audioEngine.progressTracker.currentTime)
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .overlay(YMTheme.border)

            // Main Lyrics Viewport
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if let synced = syncedLyrics, !synced.isEmpty {
                syncedKaraokeView(synced: synced)
            } else if let lyrics = supplement?.lyrics, !lyrics.displayText.isEmpty {
                staticLyricsView(text: lyrics.displayText)
            } else {
                emptyView
            }

            Divider()
                .overlay(YMTheme.border)

            // Bottom Transport Control Bar
            bottomPlaybackBar
        }
        .background {
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)

                LinearGradient(
                    colors: [
                        YMTheme.surface.opacity(0.85),
                        YMTheme.bg.opacity(0.92),
                        YMTheme.bg.opacity(0.97)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .leading) {
            YMTheme.border
                .frame(width: 1)
        }
        .shadow(color: Color.black.opacity(0.35), radius: 24, x: -6, y: 0)
        .task {
            loadLyrics()
        }
        .onChange(of: audioEngine.currentTrack?.id) { _, _ in
            loadLyrics()
        }
        .onDisappear {
            coordinator.lyricsTrack = nil
        }
    }

    // MARK: - Header Bar

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .center, spacing: 14) {
            if let track = currentTrack {
                CachedCoverImage(
                    coverUri: track.effectiveCoverUri,
                    size: .small,
                    displaySize: 42,
                    cornerRadius: 6
                )
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMTheme.fg)
                        .lineLimit(1)

                    Text(track.artistsString)
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                }
            } else {
                Text("Текст песни")
                    .font(.headline)
                    .foregroundStyle(YMTheme.fg)
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    coordinator.isLyricsPresented = false
                    coordinator.lyricsTrack = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(YMTheme.fg60)
                    .padding(8)
                    .background(Circle().fill(YMTheme.surfaceComponent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Закрыть субтитры (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(YMTheme.surface.opacity(0.5))
    }

    // MARK: - Synced Karaoke View

    @ViewBuilder
    private func syncedKaraokeView(synced: YMSyncedLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Top clearance so first lines can be centered
                    Color.clear
                        .frame(height: 100)

                    ForEach(synced.lines) { line in
                        let isActive = line.id == activeLineIndex
                        let isPast = (activeLineIndex != nil) && (line.id < activeLineIndex!)

                        KaraokeLineRow(
                            line: line,
                            isActive: isActive,
                            isPast: isPast,
                            isPlaying: audioEngine.isPlaying,
                            onSelect: {
                                audioEngine.seek(to: line.time)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    proxy.scrollTo(line.id, anchor: .center)
                                }
                            }
                        )
                        .id(line.id)
                    }

                    // Bottom clearance so final lines can reach the center
                    Color.clear
                        .frame(height: 160)
                }
                .padding(.horizontal, 24)
            }
            .onChange(of: activeLineIndex) { _, newActiveIndex in
                guard let id = newActiveIndex else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onAppear {
                if let id = activeLineIndex {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: synced.lines.count) { _, _ in
                if let id = activeLineIndex {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Static Lyrics Fallback View

    @ViewBuilder
    private func staticLyricsView(text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Color.clear.frame(height: 30)
                Text(text)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(YMTheme.fg80)
                    .lineSpacing(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 60)
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Bottom Playback Bar

    @ViewBuilder
    private var bottomPlaybackBar: some View {
        if let target = currentTrack, target.id != audioEngine.currentTrack?.id {
            HStack {
                Text("Трек сейчас не играет")
                    .font(.system(size: 12))
                    .foregroundStyle(YMTheme.fg60)

                Spacer()

                Button {
                    audioEngine.assignQueue([target], startingAt: 0)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                        Text("Слушать этот трек")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 30))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(YMTheme.surface.opacity(0.5))
        } else {
            HStack(spacing: 16) {
                // Live Time
                Text(audioEngine.progressTracker.currentTimeFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(YMTheme.fg60)
                    .frame(width: 44, alignment: .leading)

                // Seek slider
                YMSlider(
                    value: Binding(
                        get: { audioEngine.progressTracker.progress },
                        set: { newFraction in
                            audioEngine.progressTracker.progress = newFraction
                        }
                    ),
                    in: 0...1,
                    activeColor: YMTheme.accent,
                    height: 4,
                    onEditingChanged: { dragging in
                        audioEngine.progressTracker.isUserSeeking = dragging
                        if !dragging {
                            let target = audioEngine.progressTracker.currentTime
                            audioEngine.seek(to: target)
                        }
                    }
                )

                // Total Duration
                Text(audioEngine.progressTracker.durationFormatted)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(YMTheme.fg60)
                    .frame(width: 44, alignment: .trailing)

                // Jump back 10s
                Button {
                    let target = max(0, audioEngine.progressTracker.currentTime - 10)
                    audioEngine.seek(to: target)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 15))
                        .foregroundStyle(YMTheme.fg80)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Назад на 10 сек")

                // Play / Pause
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(YMTheme.accentFill)
                            .frame(width: 32, height: 32)

                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Color.black)
                    }
                }
                .buttonStyle(.plain)
                .help(audioEngine.isPlaying ? "Пауза" : "Воспроизвести")

                // Jump forward 10s
                Button {
                    let dur = audioEngine.progressTracker.duration
                    let target = min(dur, audioEngine.progressTracker.currentTime + 10)
                    audioEngine.seek(to: target)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 15))
                        .foregroundStyle(YMTheme.fg80)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Вперед на 10 сек")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(YMTheme.surface.opacity(0.5))
        }
    }

    // MARK: - State Views

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Загрузка текста песни...")
                .font(.caption)
                .foregroundStyle(YMTheme.fg40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 36))
                .foregroundStyle(YMTheme.fg40)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 36))
                .foregroundStyle(YMTheme.fg40)
            Text("К сожалению, текст для этого трека пока не добавлен в Яндекс Музыку.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading Logic

    private func loadLyrics() {
        guard let track = currentTrack else {
            isLoading = false
            errorMessage = "Сейчас ничего не воспроизводится."
            return
        }

        isLoading = true
        errorMessage = nil
        syncedLyrics = nil
        supplement = nil

        Task {
            // First attempt to fetch synced LRC lyrics
            do {
                if let synced = try await networkClient.fetchTrackLyricsLRC(trackId: track.id), !synced.isEmpty {
                    await MainActor.run {
                        self.syncedLyrics = synced
                        self.isLoading = false
                    }
                    return
                }
            } catch {
                // Ignore and proceed to supplement fallback
            }

            // Fallback to track supplement for plain text lyrics
            do {
                let supp = try await networkClient.fetchTrackSupplement(trackId: track.id)
                await MainActor.run {
                    self.supplement = supp
                    self.isLoading = false
                    if supp.lyrics == nil || supp.lyrics?.displayText.isEmpty == true {
                        self.errorMessage = "Текст для этого трека отсутствует."
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Не удалось загрузить слова песни: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Karaoke Line Row Subview

private struct KaraokeLineRow: View {
    let line: SyncedLyricLine
    let isActive: Bool
    let isPast: Bool
    let isPlaying: Bool
    let onSelect: () -> Void

    @UIState private var isHovered = false

    private var font: Font {
        .system(
            size: isActive ? 28 : 21,
            weight: isActive ? .bold : .medium,
            design: .rounded
        )
    }

    private var textColor: Color {
        if isActive {
            return YMTheme.accent
        } else if isPast {
            return YMTheme.fg40
        } else if isHovered {
            return YMTheme.fg
        } else {
            return YMTheme.fg60
        }
    }

    private var backgroundColor: Color {
        if isActive {
            return YMTheme.accent.opacity(0.12)
        } else if isHovered {
            return YMTheme.surfaceComponentHover
        } else {
            return Color.clear
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 14) {
                if isActive {
                    YMPlayingEqualizerView(
                        color: YMTheme.accent,
                        barWidth: 3,
                        maxHeight: 16,
                        isPlaying: isPlaying
                    )
                    .frame(width: 20)
                    .transition(.opacity)
                } else {
                    Color.clear
                        .frame(width: 20)
                }

                Text(line.text)
                    .font(font)
                    .foregroundStyle(textColor)
                    .shadow(color: isActive ? YMTheme.accent.opacity(0.35) : Color.clear, radius: isActive ? 10 : 0)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.2), value: isActive)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
