import SwiftUI

/// Integrated side panel for synchronized lyrics with a smooth transparent-to-background gradient,
/// prominent active phrase typography without line-wrapping jumps, and dynamic light/dark theming.
public struct LyricsSheetView: View {
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var syncedLyrics: YMSyncedLyrics? = nil
    @UIState private var supplement: YMTrackSupplement? = nil
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    private let networkClient = YMNetworkClient.shared

    public init(track: YMTrack? = nil) {
        // Parameter retained for backward compatibility; coordinator & audioEngine determine the current track
    }

    private var currentTrack: YMTrack? {
        coordinator.lyricsTrack ?? audioEngine.currentTrack
    }

    private var activeLineIndex: Int? {
        syncedLyrics?.activeLineIndex(for: audioEngine.progressTracker.currentTime)
    }

    private var baseGradientColor: Color {
        YMTheme.isLight ? YMTheme.bg : Color.black
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

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
        }
        .background {
            LinearGradient(
                stops: [
                    .init(color: baseGradientColor.opacity(0.0), location: 0.0),
                    .init(color: baseGradientColor.opacity(0.45), location: 0.05),
                    .init(color: baseGradientColor.opacity(0.85), location: 0.12),
                    .init(color: baseGradientColor.opacity(0.96), location: 0.22),
                    .init(color: baseGradientColor.opacity(0.98), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .task(id: currentTrack?.id) {
            loadLyrics()
        }
        .onChange(of: currentTrack?.id) { _, _ in
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
                .shadow(color: YMTheme.shadowColor, radius: 4, x: 0, y: 2)

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
                    .foregroundStyle(YMTheme.fg80)
                    .padding(8)
                    .background(Circle().fill(YMTheme.surfaceComponent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Закрыть субтитры (Esc)")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.clear)
    }

    // MARK: - Synced Karaoke View

    @ViewBuilder
    private func syncedKaraokeView(synced: YMSyncedLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Top clearance so first lines can be centered
                    Color.clear
                        .frame(height: 80)

                    ForEach(synced.lines) { line in
                        let isActive = line.id == activeLineIndex
                        let isPast = (activeLineIndex != nil) && (line.id < activeLineIndex!)

                        KaraokeLineRow(
                            line: line,
                            isActive: isActive,
                            isPast: isPast,
                            onSelect: {
                                audioEngine.seek(to: line.time)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                    proxy.scrollTo(line.id, anchor: .center)
                                }
                            }
                        )
                        .id(line.id)
                    }

                    // Bottom clearance so final lines can reach the center and stay above player bar
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Color.clear.frame(height: 30)
                Text(text)
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(YMTheme.fg80)
                    .lineSpacing(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 140)
            }
            .padding(.horizontal, 28)
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
                .foregroundStyle(YMTheme.fg60)
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
                .foregroundStyle(YMTheme.fg80)
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
                .foregroundStyle(YMTheme.fg80)
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
    let onSelect: () -> Void

    @UIState private var isHovered = false

    // Identical base font metrics guarantee words NEVER jump across lines when enlarging
    private static let baseFont = Font.system(size: 24, weight: .bold, design: .rounded)

    private var textColor: Color {
        if isActive {
            return YMTheme.accent
        } else if isPast {
            return YMTheme.isLight ? YMTheme.fg.opacity(0.35) : Color.white.opacity(0.35)
        } else if isHovered {
            return YMTheme.fg
        } else {
            return YMTheme.isLight ? YMTheme.fg.opacity(0.55) : Color.white.opacity(0.55)
        }
    }

    private var textScale: CGFloat {
        if isActive {
            return 1.10
        } else if isHovered {
            return 0.92
        } else {
            return 0.88
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 0) {
                Text(line.text)
                    .font(Self.baseFont)
                    .foregroundStyle(textColor)
                    .shadow(color: isActive ? YMTheme.accent.opacity(YMTheme.isLight ? 0.22 : 0.35) : Color.clear, radius: 8, x: 0, y: 0)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(textScale, anchor: .leading)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isActive)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
