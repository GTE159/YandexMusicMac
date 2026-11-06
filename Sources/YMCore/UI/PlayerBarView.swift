import SwiftUI

/// Bottom Player Bar anchored via safeAreaInset.
/// Modern macOS dark glass design with balanced symmetrical controls,
/// fixed-width quality pills, and isolated PlaybackProgressTracker redraw boundaries.
public struct PlayerBarView: View {
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var likesService = LikesService.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var isFlameActive = false
    @UIState private var isMuted = false
    @UIState private var previousVolume: Float = 1.0

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            // Left: Track cover, Title, Artist, Like
            leftTrackSection
                .frame(minWidth: windowState.isMiniWidth ? 110 : 160, maxWidth: 250, alignment: .leading)

            Spacer(minLength: 6)

            // Center: Symmetrical Playback Controls & Progress Scrubber
            centerControlsSection
                .frame(minWidth: windowState.isMiniWidth ? 160 : 280, maxWidth: 440)

            Spacer(minLength: 6)

            // Right: Lyrics, Fixed-width Quality Badge & Volume Control
            rightControlsSection
                .frame(minWidth: windowState.isMiniWidth ? 80 : 160, maxWidth: 250, alignment: .trailing)
        }
        .padding(.horizontal, windowState.isCompactWidth ? 12 : 20)
        .padding(.vertical, 8)
        .frame(height: 76)
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                VisualEffectBlur(material: .headerView, blendingMode: .withinWindow)

                LinearGradient(
                    colors: [
                        YMTheme.playerBg.opacity(0.85),
                        YMTheme.playerBg.opacity(0.96),
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
        .shadow(color: YMTheme.playerBarShadow, radius: 10, x: 0, y: -4)
    }

    // MARK: - Left Track Section

    @ViewBuilder
    private var leftTrackSection: some View {
        HStack(spacing: 10) {
            if let track = audioEngine.currentTrack {
                Button {
                    if let album = track.albums.first {
                        coordinator.navigate(to: .album(id: album.id, title: album.title))
                    }
                } label: {
                    CachedCoverImage(
                        coverUri: track.effectiveCoverUri,
                        size: .small,
                        displaySize: 44,
                        cornerRadius: 6
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .help("Перейти к альбому")

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YMTheme.fg)
                        .lineLimit(1)

                    if let firstArtist = track.artists.first {
                        Button {
                            coordinator.navigate(to: .artist(id: firstArtist.id, name: firstArtist.name))
                        } label: {
                            Text(track.artistsString)
                                .font(.system(size: 11))
                                .foregroundStyle(YMTheme.fg60)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Перейти к исполнителю")
                    } else {
                        Text(track.artistsString)
                            .font(.system(size: 11))
                            .foregroundStyle(YMTheme.fg60)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 160, alignment: .leading)
                .layoutPriority(1)

                // Heart / Like button
                Button {
                    Task {
                        await likesService.toggleLike(track: track)
                    }
                } label: {
                    Image(systemName: likesService.isLiked(trackId: track.id) ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundColor(likesService.isLiked(trackId: track.id) ? YMTheme.heartRed : YMTheme.fg60)
                        .padding(6)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help(likesService.isLiked(trackId: track.id) ? "Удалить из Мне нравится" : "Мне нравится")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(YMTheme.surfaceComponent)
                    .frame(width: 44, height: 44)

                Text("Ничего не играет")
                    .font(.system(size: 13))
                    .foregroundStyle(YMTheme.fg40)
                    .frame(maxWidth: 160, alignment: .leading)
            }
        }
    }

    // MARK: - Center Controls Section (Strictly Symmetrical)

    @ViewBuilder
    private var centerControlsSection: some View {
        VStack(spacing: 6) {
            // Row 1: Symmetrical Playback Controls
            HStack(spacing: windowState.isMiniWidth ? 10 : 16) {
                if audioEngine.isWaveMode {
                    if !windowState.isMiniWidth {
                        // Button 1 (Leftmost): Dislike
                        Button {
                            audioEngine.applyWaveTuning(.lessLikeThis)
                        } label: {
                            Image(systemName: "hand.thumbsdown.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(YMTheme.fg60)
                                .padding(6)
                                .background(Circle().fill(YMTheme.surfaceComponent))
                        }
                        .buttonStyle(.plain)
                        .disabled(audioEngine.currentTrack == nil)
                        .help("Меньше таких треков")
                    }

                    // Button 2: Previous Track
                    previousButton

                    // Button 3 (Center): Play / Pause (Prominent Yellow Disc)
                    playPauseButton

                    // Button 4: Next Track
                    nextButton

                    if !windowState.isMiniWidth {
                        // Button 5 (Rightmost): Flame (More Like This)
                        Button {
                            audioEngine.applyWaveTuning(.moreLikeThis)
                            isFlameActive = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                await MainActor.run {
                                    isFlameActive = false
                                }
                            }
                        } label: {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(isFlameActive ? Color.orange : YMTheme.accent)
                                .padding(6)
                                .background(Circle().fill(YMTheme.surfaceComponent))
                        }
                        .buttonStyle(.plain)
                        .disabled(audioEngine.currentTrack == nil)
                        .help("Больше таких треков")
                    }
                } else {
                    if !windowState.isMiniWidth {
                        // Button 1 (Leftmost): Shuffle
                        Button {
                            audioEngine.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 12))
                                .foregroundStyle(audioEngine.isShuffleEnabled ? YMTheme.accent : YMTheme.fg60)
                                .padding(6)
                                .background(Circle().fill(audioEngine.isShuffleEnabled ? YMTheme.accent.opacity(0.18) : YMTheme.surfaceComponent))
                        }
                        .buttonStyle(.plain)
                        .disabled(audioEngine.currentTrack == nil && audioEngine.queue.isEmpty)
                        .help(audioEngine.isShuffleEnabled ? "Выключить перемешивание" : "Перемешать очередь")
                    }

                    // Button 2: Previous Track
                    previousButton

                    // Button 3 (Center): Play / Pause
                    playPauseButton

                    // Button 4: Next Track
                    nextButton

                    if !windowState.isMiniWidth {
                        // Button 5 (Rightmost): Start Wave from Current Track
                        Button {
                            if let track = audioEngine.currentTrack {
                                audioEngine.startWave(forTrack: track)
                            }
                        } label: {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 12))
                                .foregroundStyle(YMTheme.fg60)
                                .padding(6)
                                .background(Circle().fill(YMTheme.surfaceComponent))
                        }
                        .buttonStyle(.plain)
                        .disabled(audioEngine.currentTrack == nil)
                        .help("Запустить Мою волну по текущему треку")
                    }
                }
            }

            // Row 2: Isolated Scrubber View
            IsolatedProgressSlider(
                progressTracker: audioEngine.progressTracker,
                onSeekCommit: { seconds in
                    audioEngine.seek(to: seconds)
                }
            )
        }
    }

    @ViewBuilder
    private var previousButton: some View {
        Button {
            audioEngine.previous()
        } label: {
            Image(systemName: "backward.fill")
                .font(.system(size: 13))
                .foregroundStyle(audioEngine.currentTrack == nil ? YMTheme.fg40 : YMTheme.fg80)
                .padding(6)
        }
        .buttonStyle(.plain)
        .disabled(audioEngine.currentTrack == nil)
        .help("Предыдущий трек")
    }

    @ViewBuilder
    private var playPauseButton: some View {
        Button {
            audioEngine.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(YMTheme.accentFill)
                    .frame(width: 38, height: 38)
                    .shadow(color: YMTheme.accentFill.opacity(audioEngine.isPlaying ? 0.35 : 0.15), radius: 6, y: 1)

                Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color.black)
                    .offset(x: audioEngine.isPlaying ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(audioEngine.currentTrack == nil)
        .help(audioEngine.isPlaying ? "Пауза (Пробел)" : "Воспроизведение (Пробел)")
    }

    @ViewBuilder
    private var nextButton: some View {
        Button {
            audioEngine.next()
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 13))
                .foregroundStyle(audioEngine.currentTrack == nil ? YMTheme.fg40 : YMTheme.fg80)
                .padding(6)
        }
        .buttonStyle(.plain)
        .disabled(audioEngine.currentTrack == nil)
        .help("Следующий трек")
    }

    // MARK: - Right Controls Section

    @ViewBuilder
    private var rightControlsSection: some View {
        HStack(spacing: 12) {
            // Lyrics Button (only shown if lyrics are available)
            if let track = audioEngine.currentTrack, track.hasLyrics {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if coordinator.isLyricsPresented {
                            coordinator.isLyricsPresented = false
                            coordinator.lyricsTrack = nil
                        } else {
                            coordinator.showLyrics(for: track)
                        }
                    }
                } label: {
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(coordinator.isLyricsPresented ? YMTheme.accent : YMTheme.fg60)
                        .padding(6)
                        .background(Circle().fill(coordinator.isLyricsPresented ? YMTheme.accent.opacity(0.18) : YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help("Показать текст песни")
            }

            // Fixed-Width Quality Badge Menu (hidden in mini mode to prevent crowding)
            if !windowState.isMiniWidth {
                AudioQualityMenu(audioEngine: audioEngine)
            }

            // Volume Control
            HStack(spacing: 6) {
                Button {
                    toggleMute()
                } label: {
                    Image(systemName: volumeIcon)
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg60)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Включить звук" : "Выключить звук")

                YMSlider(
                    value: Binding(
                        get: { Double(audioEngine.volume) },
                        set: {
                            audioEngine.volume = Float($0)
                            if $0 > 0 { isMuted = false }
                        }
                    ),
                    in: 0...1,
                    activeColor: YMTheme.fg,
                    trackColor: YMTheme.surfaceComponentHover,
                    height: 3
                )
                .frame(width: windowState.isMiniWidth ? 46 : 68)
            }
        }
    }

    private var volumeIcon: String {
        if isMuted || audioEngine.volume == 0 {
            return "speaker.slash.fill"
        } else if audioEngine.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if audioEngine.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func toggleMute() {
        if isMuted {
            audioEngine.volume = previousVolume > 0 ? previousVolume : 0.5
            isMuted = false
        } else {
            previousVolume = audioEngine.volume
            audioEngine.volume = 0
            isMuted = true
        }
    }
}

// MARK: - Audio Quality Dropdown Menu (Fixed Width, No Icon)

private struct AudioQualityMenu: View {
    @Bindable var audioEngine: AudioPlayerEngine
    @Bindable var qualitySettings = AudioQualitySettings.shared

    var body: some View {
        Menu {
            Section("Качество звука") {
                ForEach(YMAudioQualityPreset.allCases) { preset in
                    Button {
                        audioEngine.setAudioQualityPreset(preset)
                    } label: {
                        HStack {
                            Text(preset.title)
                            if qualitySettings.preset == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Предпочитаемый кодек") {
                ForEach(YMAudioCodecPreference.allCases) { codec in
                    Button {
                        audioEngine.setCodecPreference(codec)
                    } label: {
                        HStack {
                            Text(codec.title)
                            if qualitySettings.codecPreference == codec {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if let formatDetails = audioEngine.currentAudioFormatDetails {
                Section("Аппаратный поток (AVPlayer)") {
                    Text(formatDetails)
                }
            }

            if !audioEngine.availableStreamInfos.isEmpty {
                Section("Доступные потоки трека") {
                    ForEach(audioEngine.availableStreamInfos) { info in
                        Button {
                            audioEngine.selectStreamVariant(info)
                        } label: {
                            HStack {
                                Text(info.displayDescription)
                                if audioEngine.currentStreamInfo?.matchesVariant(info) == true {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Text(badgeTitle)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
                .frame(width: 76, alignment: .center)
                .padding(.vertical, 4)
                .background(badgeBackground)
                .foregroundColor(badgeForeground)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(isLosslessActive ? YMTheme.accent.opacity(0.3) : YMTheme.border, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .frame(width: 76)
        .fixedSize()
        .help("Настройки качества звука")
    }

    private var badgeTitle: String {
        if let info = audioEngine.currentStreamInfo {
            if info.isLossless {
                return "LOSSLESS"
            }
            let codec = info.displayCodec.replacingOccurrences(of: "(MP4)", with: "").trimmingCharacters(in: .whitespaces)
            return "\(info.bitrateInKbps)K \(codec)"
        }
        return audioEngine.qualitySettings.preset.shortBadge
    }

    private var isLosslessActive: Bool {
        audioEngine.currentStreamInfo?.isLossless == true || audioEngine.qualitySettings.preset == .lossless
    }

    private var badgeBackground: Color {
        if isLosslessActive {
            return YMTheme.accent.opacity(0.18)
        }
        return YMTheme.surfaceComponent
    }

    private var badgeForeground: Color {
        if isLosslessActive {
            return YMTheme.accent
        }
        return YMTheme.fg80
    }
}

// MARK: - Isolated Progress Slider

/// Isolated Slider component bound only to `PlaybackProgressTracker`.
/// High-frequency ticks (up to 4-10 times/sec) do not re-render the parent PlayerBar or Navigation split view.
private struct IsolatedProgressSlider: View {
    @Bindable var progressTracker: PlaybackProgressTracker
    let onSeekCommit: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(progressTracker.currentTimeFormatted)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(YMTheme.fg60)
                .frame(width: 36, alignment: .trailing)

            YMSlider(
                value: Binding(
                    get: { progressTracker.progress },
                    set: { progressTracker.progress = $0 }
                ),
                in: 0...1,
                activeColor: YMTheme.accent,
                trackColor: YMTheme.surfaceComponentHover,
                height: 3,
                onEditingChanged: { editing in
                    progressTracker.isUserSeeking = editing
                    if !editing {
                        onSeekCommit(progressTracker.currentTime)
                    }
                }
            )

            Text(progressTracker.durationFormatted)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(YMTheme.fg40)
                .frame(width: 36, alignment: .leading)
        }
    }
}
