import SwiftUI

/// Compact 3-line docked lyrics bar displayed directly above the bottom player bar.
/// Shows: Previous line, Current line (highlighted & bold), and Next line with interactive seeking.
public struct AbovePlayerLyricsBar: View {
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var themeManager = YMThemeManager.shared
    @UIState private var syncedLyrics: YMSyncedLyrics? = nil
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    private let networkClient = YMNetworkClient.shared

    public init() {}

    private var currentTrack: YMTrack? {
        coordinator.lyricsTrack ?? audioEngine.currentTrack
    }

    private var activeLineIndex: Int? {
        syncedLyrics?.activeLineIndex(for: audioEngine.progressTracker.currentTime)
    }

    private var prevLine: SyncedLyricLine? {
        guard let idx = activeLineIndex, let synced = syncedLyrics, idx > 0, idx - 1 < synced.lines.count else {
            return nil
        }
        return synced.lines[idx - 1]
    }

    private var currLine: SyncedLyricLine? {
        guard let synced = syncedLyrics, !synced.isEmpty else { return nil }
        if let idx = activeLineIndex, idx < synced.lines.count {
            return synced.lines[idx]
        }
        return synced.lines.first
    }

    private var nextLine: SyncedLyricLine? {
        guard let synced = syncedLyrics, !synced.isEmpty else { return nil }
        let nextIdx = (activeLineIndex ?? 0) + 1
        guard nextIdx < synced.lines.count else { return nil }
        return synced.lines[nextIdx]
    }

    public var body: some View {
        HStack(spacing: 16) {
            // Left: Mini Track Information (hidden in mini mode)
            if !windowState.isMiniWidth, let track = currentTrack {
                HStack(spacing: 8) {
                    CachedCoverImage(
                        coverUri: track.effectiveCoverUri,
                        size: .small,
                        displaySize: 34,
                        cornerRadius: 4
                    )
                    .shadow(color: YMTheme.shadowColor, radius: 3, x: 0, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.displayTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        Text(track.artistsString)
                            .font(.system(size: 10))
                            .foregroundStyle(YMTheme.fg60)
                            .lineLimit(1)
                    }
                }
                .frame(width: windowState.isCompactWidth ? 110 : 160, alignment: .leading)
            }

            Spacer(minLength: 4)

            // Center: 3 Synchronized Karaoke Lines (Previous, Active, Next)
            VStack(spacing: 2) {
                // Line 1: Previous Line
                if let prev = prevLine {
                    Button {
                        audioEngine.seek(to: prev.time)
                    } label: {
                        Text(prev.text)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg40)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Перемотать к предыдущей строке")
                } else {
                    Text(" ")
                        .font(.system(size: 11))
                }

                // Line 2: Active Line (Enlarged, Bold, Accent Colored)
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Загрузка текста песни...")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg60)
                    }
                } else if let curr = currLine {
                    Text(curr.text)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(YMTheme.accent)
                        .shadow(color: YMTheme.accent.opacity(YMTheme.isLight ? 0.22 : 0.35), radius: 6, x: 0, y: 0)
                        .lineLimit(1)
                        .id(curr.id)
                } else if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                } else {
                    Text("Текст песни для этого трека недоступен")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                }

                // Line 3: Next Line
                if let next = nextLine {
                    Button {
                        audioEngine.seek(to: next.time)
                    } label: {
                        Text(next.text)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg40)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Перемотать к следующей строке")
                } else {
                    Text(" ")
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.22), value: activeLineIndex)

            Spacer(minLength: 4)

            // Right: Close Button
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        coordinator.isLyricsPresented = false
                        coordinator.lyricsTrack = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(YMTheme.fg80)
                        .padding(6)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help("Закрыть текст песни (Esc)")
            }
            .frame(width: windowState.isMiniWidth ? 30 : 60, alignment: .trailing)
        }
        .padding(.horizontal, windowState.isCompactWidth ? 12 : 20)
        .padding(.vertical, 6)
        .frame(height: 78)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)

                LinearGradient(
                    colors: [
                        YMTheme.playerBg.opacity(0.92),
                        YMTheme.playerBg.opacity(0.98),
                        YMTheme.playerBg
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .overlay(alignment: .top) {
            YMTheme.border
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            YMTheme.border.opacity(0.5)
                .frame(height: 1)
        }
        .task(id: currentTrack?.id) {
            loadLyrics()
        }
        .onChange(of: currentTrack?.id) { _, _ in
            loadLyrics()
        }
    }

    private func loadLyrics() {
        guard let track = currentTrack else {
            isLoading = false
            syncedLyrics = nil
            return
        }

        isLoading = true
        errorMessage = nil
        syncedLyrics = nil

        Task {
            do {
                if let synced = try await networkClient.fetchTrackLyricsLRC(trackId: track.id), !synced.isEmpty {
                    await MainActor.run {
                        self.syncedLyrics = synced
                        self.isLoading = false
                    }
                    return
                }
            } catch {
                // Ignore LRC failure, fall back below
            }

            // Fallback: check if supplement exists
            do {
                let supp = try await networkClient.fetchTrackSupplement(trackId: track.id)
                await MainActor.run {
                    self.isLoading = false
                    if supp.lyrics == nil || supp.lyrics?.displayText.isEmpty == true {
                        self.errorMessage = "Текст песни отсутствует"
                    } else {
                        self.errorMessage = "Караоке-синхронизация недоступна"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "Не удалось загрузить текст"
                }
            }
        }
    }
}
