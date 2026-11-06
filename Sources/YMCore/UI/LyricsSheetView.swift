import SwiftUI

/// Modern macOS Karaoke & Lyrics sheet featuring synchronized real-time LRC scrolling,
/// active line glowing highlights, tap-to-seek, and interactive transport controls.
public struct LyricsSheetView: View {
    public let track: YMTrack?
    @Environment(\.dismiss) private var dismiss

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
        audioEngine.currentTrack ?? track
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
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 650, minHeight: 520, idealHeight: 640)
        .ymScreenBackground()
        .task {
            loadLyrics()
        }
        .onChange(of: audioEngine.currentTrack?.id) { _, _ in
            loadLyrics()
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
                    displaySize: 44,
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

            if syncedLyrics != nil && !(syncedLyrics?.isEmpty ?? true) {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("КАРАОКЕ")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(YMTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(YMTheme.accent.opacity(0.16))
                        .overlay(Capsule().strokeBorder(YMTheme.accent.opacity(0.35), lineWidth: 1))
                )
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(YMTheme.fg40)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Закрыть")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(YMTheme.surface)
    }

    // MARK: - Synced Karaoke View

    @ViewBuilder
    private func syncedKaraokeView(synced: YMSyncedLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Generous top clearance so first lines can be vertically centered
                    Color.clear
                        .frame(height: 120)

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
                        .frame(height: 180)
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                Text(text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(YMTheme.fg80)
                    .lineSpacing(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(32)
        }
    }

    // MARK: - Bottom Playback Bar

    @ViewBuilder
    private var bottomPlaybackBar: some View {
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
        .background(YMTheme.surface)
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
        .system(size: isActive ? 24 : 18, weight: isActive ? .bold : .medium, design: .rounded)
    }

    private var textColor: Color {
        if isActive {
            return YMTheme.accent
        } else if isPast {
            return YMTheme.fg40
        } else if isHovered {
            return YMTheme.fg
        } else {
            return YMTheme.fg80
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
            HStack(alignment: .center, spacing: 12) {
                if isActive {
                    YMPlayingEqualizerView(
                        color: YMTheme.accent,
                        barWidth: 2.5,
                        maxHeight: 14,
                        isPlaying: isPlaying
                    )
                    .frame(width: 18)
                    .transition(.opacity)
                } else {
                    Color.clear
                        .frame(width: 18)
                }

                Text(line.text)
                    .font(font)
                    .foregroundStyle(textColor)
                    .shadow(color: isActive ? YMTheme.accent.opacity(0.4) : Color.clear, radius: isActive ? 10 : 0)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.2), value: isActive)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
