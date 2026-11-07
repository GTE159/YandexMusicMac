import SwiftUI

/// Compact 3-line docked lyrics bar displayed directly above the bottom player bar.
/// Features a gentle vertical transparency gradient (no solid plate or borders)
/// with the active and neighboring lines perfectly centered over the playback controls.
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

    private var baseGradientColor: Color {
        YMTheme.isLight ? YMTheme.bg : Color.black
    }

    public var body: some View {
        ZStack(alignment: .center) {
            // Center: 3 Synchronized Karaoke Lines positioned directly over the Play/Pause button
            VStack(spacing: 3) {
                // Line 1: Previous Line
                if let prev = prevLine {
                    Button {
                        audioEngine.seek(to: prev.time)
                    } label: {
                        Text(prev.text)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg40)
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .help("Перемотать к предыдущей строке")
                } else {
                    Text(" ")
                        .font(.system(size: 11))
                }

                // Line 2: Active Line (Centered, Bold, Accent Colored with glow)
                if isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.65)
                        Text("Загрузка текста песни...")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(YMTheme.fg60)
                    }
                } else if let curr = currLine {
                    Text(curr.text)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(YMTheme.accent)
                        .shadow(color: YMTheme.accent.opacity(YMTheme.isLight ? 0.22 : 0.35), radius: 6, x: 0, y: 0)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .id(curr.id)
                } else if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Текст песни для этого трека недоступен")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
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
                            .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .help("Перемотать к следующей строке")
                } else {
                    Text(" ")
                        .font(.system(size: 11))
                }
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 48)
            .animation(.easeInOut(duration: 0.22), value: activeLineIndex)

            // Right: Subtle Close Button pinned to trailing edge (does not displace center alignment)
            HStack {
                Spacer()

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
                .padding(.trailing, windowState.isCompactWidth ? 12 : 20)
            }
        }
        .padding(.vertical, 4)
        .frame(height: 74)
        .frame(maxWidth: .infinity)
        .background {
            // Light, airy vertical gradient fading down to the player bar without boxed plate borders
            LinearGradient(
                stops: [
                    .init(color: baseGradientColor.opacity(0.0), location: 0.0),
                    .init(color: baseGradientColor.opacity(0.20), location: 0.30),
                    .init(color: baseGradientColor.opacity(0.60), location: 0.70),
                    .init(color: baseGradientColor.opacity(0.90), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .task(id: currentTrack?.id) {
            await loadLyricsAsync()
        }
    }

    @MainActor
    private func loadLyricsAsync() async {
        guard let track = currentTrack else {
            isLoading = false
            syncedLyrics = nil
            return
        }

        let requestedTrackId = track.id
        isLoading = true
        errorMessage = nil
        syncedLyrics = nil

        do {
            if let synced = try await networkClient.fetchTrackLyricsLRC(trackId: requestedTrackId), !synced.isEmpty {
                guard !Task.isCancelled, currentTrack?.id == requestedTrackId else { return }
                self.syncedLyrics = synced
                self.isLoading = false
                return
            }
        } catch {
            // Fallback below
        }

        guard !Task.isCancelled, currentTrack?.id == requestedTrackId else { return }

        do {
            let supp = try await networkClient.fetchTrackSupplement(trackId: requestedTrackId)
            guard !Task.isCancelled, currentTrack?.id == requestedTrackId else { return }
            self.isLoading = false
            if supp.lyrics == nil || supp.lyrics?.displayText.isEmpty == true {
                self.errorMessage = "Текст песни отсутствует"
            } else {
                self.errorMessage = "Караоке-синхронизация недоступна"
            }
        } catch {
            guard !Task.isCancelled, currentTrack?.id == requestedTrackId else { return }
            self.isLoading = false
            self.errorMessage = "Не удалось загрузить текст"
        }
    }
}
