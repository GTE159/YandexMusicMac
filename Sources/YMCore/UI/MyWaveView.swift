import SwiftUI

/// Modern, visually stunning "Моя волна" view inspired by the official Yandex Music web design.
/// Features a cinematic Aurora Nebula background, massive typography, floating album cover,
/// glass capsule track pill with volume and animated equalizers, prominent playback controls,
/// interactive vibe selectors, and the upcoming wave queue.
/// Does NOT auto-play on navigation.
public struct MyWaveView: View {
    @UIState private var waveTracks: [YMTrack] = []
    @UIState private var rotorService = RotorService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var likesService = LikesService.shared

    @UIState private var isLoadingWave = false
    @UIState private var isLoadingMoreWave = false
    @UIState private var errorMessage: String? = nil
    @UIState private var toastMessage: String? = nil
    @UIState private var toastDismissTask: Task<Void, Never>? = nil

    @UIState private var waveOrbRotation: Double = 0
    @UIState private var waveOrbScale: CGFloat = 1.0
    @UIState private var isFlameActive: Bool = false
    @UIState private var isMuted: Bool = false
    @UIState private var previousVolume: Float = 1.0

    public init() {}

    private var displayedWaveTracks: [YMTrack] {
        if audioEngine.isWaveMode && !audioEngine.queue.isEmpty {
            return audioEngine.queue
        }
        return waveTracks
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 28) {
                // Main Cinematic Hero Stage
                waveHeroStage

                // Vibe / Mood Selectors
                vibePresetsSelector

                // Tuning Feedback Toast
                if let toast = toastMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundColor(YMTheme.accent)
                            .font(.system(size: 13, weight: .bold))
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
                            .overlay(Capsule().strokeBorder(YMTheme.accent.opacity(0.4), lineWidth: 1))
                            .shadow(color: YMTheme.accent.opacity(0.2), radius: 8)
                    )
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Error message banner
                if let error = errorMessage {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Ошибка загрузки волны: \(error)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Повторить") {
                            startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                    )
                    .padding(.horizontal, 24)
                }

                // Upcoming Wave Queue Section: "Далее в волне"
                if !displayedWaveTracks.isEmpty || isLoadingWave {
                    upcomingQueueSection
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 80)
        }
        .ymScreenBackground()
        .onAppear {
            // NEVER auto-start playback on navigation
            if audioEngine.isWaveMode && !audioEngine.queue.isEmpty {
                waveTracks = audioEngine.queue
            }
            setupWaveChangeHooks()
            withAnimation(.linear(duration: 25).repeatForever(autoreverses: false)) {
                waveOrbRotation = 360
            }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                waveOrbScale = 1.15
            }
        }
    }

    // MARK: - Hero Stage (Yandex Music Aurora Nebula)

    @ViewBuilder
    private var waveHeroStage: some View {
        ZStack {
            // Ambient Aurora Nebula
            auroraNebulaBackground

            // Foreground Content
            if let track = audioEngine.currentTrack, audioEngine.isWaveMode {
                activeWaveContent(track: track)
            } else {
                idleWaveContent
            }
        }
        .frame(minHeight: 400)
        .padding(.horizontal, 24)
    }

    // MARK: - Aurora Nebula Background

    private var auroraNebulaBackground: some View {
        ZStack {
            // Deep cosmic container
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 16 / 255, green: 14 / 255, blue: 18 / 255),
                            Color(red: 10 / 255, green: 10 / 255, blue: 14 / 255),
                            Color.black
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            // Luminous Outer Nebula Aura
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 235 / 255, green: 20 / 255, blue: 120 / 255).opacity(audioEngine.isPlaying ? 0.35 : 0.18),
                            Color(red: 255 / 255, green: 140 / 255, blue: 0 / 255).opacity(audioEngine.isPlaying ? 0.30 : 0.15),
                            Color(red: 120 / 255, green: 30 / 255, blue: 200 / 255).opacity(audioEngine.isPlaying ? 0.22 : 0.10),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 180
                    )
                )
                .frame(width: 360, height: 360)
                .scaleEffect(audioEngine.isPlaying ? waveOrbScale : 1.0)
                .blur(radius: 40)

            // Dynamic Rotating Core Mesh
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color(red: 255 / 255, green: 210 / 255, blue: 0 / 255),
                            Color(red: 255 / 255, green: 90 / 255, blue: 20 / 255),
                            Color(red: 235 / 255, green: 20 / 255, blue: 120 / 255),
                            Color(red: 130 / 255, green: 30 / 255, blue: 210 / 255),
                            Color(red: 30 / 255, green: 144 / 255, blue: 255 / 255),
                            Color(red: 255 / 255, green: 210 / 255, blue: 0 / 255)
                        ],
                        center: .center
                    )
                )
                .frame(width: 210, height: 210)
                .rotationEffect(.degrees(waveOrbRotation))
                .blur(radius: 28)
                .opacity(audioEngine.isPlaying ? 0.85 : 0.45)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Active Wave Content (Like Yandex Music Web)

    @ViewBuilder
    private func activeWaveContent(track: YMTrack) -> some View {
        VStack(spacing: 16) {
            // Top Tag: Wave Context Chip
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                    Text(audioEngine.activeWaveContext.title)
                        .font(.system(size: 12, weight: .semibold))

                    if audioEngine.activeWaveContext != .myWaveDefault {
                        Button {
                            startWave(context: .myWaveDefault, vibe: audioEngine.activeWaveVibe)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(YMTheme.fg60)
                        }
                        .buttonStyle(.plain)
                        .help("Сбросить к обычной Моей волне")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .foregroundColor(YMTheme.accent)
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)

            // Massive Cinematic Artist Title
            Button {
                if let artist = track.artists.first {
                    coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                }
            } label: {
                Text(track.artistsString)
                    .font(.system(size: windowState.isCompactWidth ? 34 : 46, weight: .black, design: .default))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .shadow(color: Color.black.opacity(0.6), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)

            // Floating Album Cover
            Button {
                if let album = track.albums.first {
                    coordinator.navigate(to: .album(id: album.id, title: album.title))
                }
            } label: {
                CachedCoverImage(
                    coverUri: track.effectiveCoverUri,
                    size: .medium,
                    displaySize: 114,
                    cornerRadius: 16
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.6), radius: 18, x: 0, y: 8)
                .scaleEffect(audioEngine.isPlaying ? 1.02 : 1.0)
            }
            .buttonStyle(.plain)
            .help("Перейти к альбому")

            // Floating Translucent Glass Capsule Pill (Directly below Cover)
            HStack(spacing: 12) {
                // Mute / Speaker toggle
                Button {
                    toggleMute()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Включить звук" : "Выключить звук")

                // Track Title + Mini Equalizer
                Text(track.displayTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                YMPlayingEqualizerView(
                    color: YMTheme.accent,
                    barWidth: 2,
                    maxHeight: 12,
                    isPlaying: audioEngine.isPlaying
                )

                // Heart (Like) button
                Button {
                    Task {
                        await likesService.toggleLike(track: track)
                    }
                } label: {
                    Image(systemName: likesService.isLiked(trackId: track.id) ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundColor(likesService.isLiked(trackId: track.id) ? YMTheme.heartRed : YMTheme.fg60)
                }
                .buttonStyle(.plain)
                .help("Мне нравится")

                // More Menu
                Menu {
                    if let album = track.albums.first {
                        Button("Перейти к альбому") {
                            coordinator.navigate(to: .album(id: album.id, title: album.title))
                        }
                    }
                    if let artist = track.artists.first {
                        Button("Перейти к артисту") {
                            coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                        }
                    }
                    Divider()
                    Button("Копировать ссылку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("https://music.yandex.ru/track/\(track.id)", forType: .string)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.4), radius: 10, y: 4)
            )

            // Playback Controls Row (Symmetrical & Prominent)
            HStack(spacing: 28) {
                // Dislike
                Button {
                    audioEngine.applyWaveTuning(.lessLikeThis)
                    showToast("Меньше таких треков в волне")
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(YMTheme.fg60)
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Меньше таких треков")

                // Previous
                Button {
                    audioEngine.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(YMTheme.fg80)
                }
                .buttonStyle(.plain)
                .help("Предыдущий трек")

                // Signature Large Yellow Play / Pause Disc (56x56 pt)
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(YMTheme.accent)
                            .frame(width: 56, height: 56)
                            .shadow(color: YMTheme.accent.opacity(audioEngine.isPlaying ? 0.45 : 0.2), radius: 12, y: 2)

                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Color.black)
                            .offset(x: audioEngine.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .help(audioEngine.isPlaying ? "Пауза" : "Воспроизведение")

                // Next
                Button {
                    audioEngine.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(YMTheme.fg80)
                }
                .buttonStyle(.plain)
                .help("Следующий трек")

                // Flame (More Like This)
                Button {
                    audioEngine.applyWaveTuning(.moreLikeThis)
                    isFlameActive = true
                    showToast("Больше треков в стиле «\(track.displayTitle)»")
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { isFlameActive = false }
                    }
                } label: {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isFlameActive ? Color.orange : YMTheme.accent)
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.4)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Больше таких треков")
            }
            .padding(.top, 4)

            // AI Insight Pill (At bottom of Hero)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                    Text("AI")
                        .font(.system(size: 10, weight: .black))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(YMTheme.accent.opacity(0.2)))
                .foregroundColor(YMTheme.accent)

                Text(aiInsightText(for: track))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(YMTheme.fg60)
                    .lineLimit(1)
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Idle / Ready Wave Content (No Auto-Play)

    @ViewBuilder
    private var idleWaveContent: some View {
        VStack(spacing: 18) {
            Spacer()

            // Giant Title
            VStack(spacing: 6) {
                Text("Моя волна")
                    .font(.system(size: windowState.isCompactWidth ? 38 : 52, weight: .black, design: .default))
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.7), radius: 10, y: 4)

                Text("Бесконечный персональный поток музыки, который подстраивается под вас")
                    .font(.system(size: 14))
                    .foregroundStyle(YMTheme.fg60)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            // Prominent Play Disc
            Button {
                startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(YMTheme.accent)
                            .frame(width: 60, height: 60)
                            .shadow(color: YMTheme.accent.opacity(0.4), radius: 14, y: 3)

                        Image(systemName: "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color.black)
                            .offset(x: 2)
                    }

                    Text("Слушать Мою волну")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.45))
                        .overlay(Capsule().strokeBorder(YMTheme.accent.opacity(0.4), lineWidth: 1.5))
                )
            }
            .buttonStyle(.plain)
            .scaleEffect(waveOrbScale * 0.95)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: waveOrbScale)

            Spacer()
        }
        .frame(minHeight: 360)
    }

    // MARK: - Vibe Presets Selector (Stylized Cards)

    private var vibePresetsSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Характер звучания")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(YMTheme.fg)

                Spacer()

                // Diversity "Больше открытий" Button
                Button {
                    audioEngine.applyWaveTuning(.moreDiversity)
                    showToast("Перенастройка волны: добавлено больше открытий")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                        Text("Встряхнуть поток")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .foregroundColor(YMTheme.fg)
                    .overlay(Capsule().strokeBorder(YMTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Встряхнуть и добавить больше неожиданных треков")
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(YMWaveVibePreset.allCases) { preset in
                        let isSelected = audioEngine.activeWaveVibe == preset
                        Button {
                            audioEngine.activeWaveVibe = preset
                            if audioEngine.isWaveMode {
                                startWave(context: audioEngine.activeWaveContext, vibe: preset)
                            }
                            showToast("Характер волны: \(preset.title)")
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: preset.iconName)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(vibeColor(for: preset))

                                Text(preset.title)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? Color.black : YMTheme.fg)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(isSelected ? YMTheme.accent : Color.white.opacity(0.07))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? YMTheme.accent : YMTheme.border, lineWidth: 1)
                            )
                            .shadow(color: isSelected ? YMTheme.accent.opacity(0.25) : Color.clear, radius: 8)
                            .scaleEffect(isSelected ? 1.03 : 1.0)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
        }
    }

    private func vibeColor(for preset: YMWaveVibePreset) -> Color {
        switch preset {
        case .defaultWave: return Color(red: 255 / 255, green: 215 / 255, blue: 0)
        case .energetic: return Color(red: 0, green: 220 / 255, blue: 140 / 255)
        case .unfamiliar: return Color(red: 255 / 255, green: 145 / 255, blue: 0)
        case .familiar: return Color(red: 255 / 255, green: 210 / 255, blue: 0)
        case .popular: return Color(red: 255 / 255, green: 70 / 255, blue: 70 / 255)
        case .calm: return Color(red: 170 / 255, green: 110 / 255, blue: 245 / 255)
        }
    }

    // MARK: - Upcoming Queue Section

    @ViewBuilder
    private var upcomingQueueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Далее в волне")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(YMTheme.fg)

                    Text("Треки, подобранные алгоритмом на основе ваших предпочтений")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }

                Spacer()

                if isLoadingMoreWave {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 24)

            if displayedWaveTracks.isEmpty && isLoadingWave {
                VStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Подбираем музыку для вашей волны...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else if !displayedWaveTracks.isEmpty {
                TrackTableView(
                    tracks: displayedWaveTracks,
                    onPlayTrack: { track in
                        if let idx = displayedWaveTracks.firstIndex(where: { $0.id == track.id }) {
                            audioEngine.playTrack(at: idx)
                        }
                    },
                    onLoadMore: {
                        Task {
                            await loadMoreTracks()
                        }
                    }
                )
                .padding(.horizontal, 14)
            }
        }
    }

    // MARK: - AI Context Insights

    private func aiInsightText(for track: YMTrack) -> String {
        switch audioEngine.activeWaveVibe {
        case .energetic:
            return "Бодрый ритм • Отлично подходит для активных действий"
        case .calm:
            return "Спокойная атмосфера • Плавное звучание для отдыха"
        case .unfamiliar:
            return "Свежее открытие • Рекомендовано на основе ваших вкусов"
        case .familiar:
            return "Проверенный трек • На основе вашей медиатеки"
        case .popular:
            return "Популярный трек • Сейчас слушают многие в Яндекс Музыке"
        case .defaultWave:
            return "Специально для вас • Алгоритм Моей волны"
        }
    }

    // MARK: - Audio Helpers

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

    // MARK: - Wave Logic & Telemetry

    private func startWave(context: YMWaveContext, vibe: YMWaveVibePreset) {
        isLoadingWave = true
        errorMessage = nil

        Task {
            do {
                let initialTracks = try await rotorService.startWave(context: context, vibe: vibe)
                await MainActor.run {
                    self.waveTracks = initialTracks
                    self.isLoadingWave = false
                    self.audioEngine.activeWaveContext = context
                    self.audioEngine.activeWaveVibe = vibe
                    self.audioEngine.isWaveMode = true
                    self.audioEngine.setQueue(initialTracks, startingAt: 0)
                }
            } catch {
                await MainActor.run {
                    self.isLoadingWave = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadMoreTracks() async {
        guard !isLoadingMoreWave, let lastTrack = waveTracks.last else { return }
        isLoadingMoreWave = true

        let history = Array(waveTracks.suffix(5)).map(\.rotorTrackIdentifier)
        do {
            let nextBatch = try await rotorService.fetchNextBatch(
                lastTrackId: lastTrack.rotorTrackIdentifier,
                queueHistory: history
            )
            await MainActor.run {
                let existingIds = Set(self.waveTracks.map(\.id))
                let newUnique = nextBatch.filter { !existingIds.contains($0.id) }
                self.waveTracks.append(contentsOf: newUnique)
                self.audioEngine.appendToQueue(newUnique)
                self.isLoadingMoreWave = false
            }
        } catch {
            await MainActor.run {
                self.isLoadingMoreWave = false
            }
        }
    }

    private func setupWaveChangeHooks() {
        audioEngine.onQueueNeedsMoreTracks = {
            Task {
                await loadMoreTracks()
            }
        }

        audioEngine.onStartCustomWaveRequested = { [self] context, vibe in
            Task { @MainActor in
                self.startWave(context: context, vibe: vibe ?? .defaultWave)
            }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastDismissTask?.cancel()
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                withAnimation {
                    self.toastMessage = nil
                }
            }
        }
    }
}
