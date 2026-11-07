import SwiftUI

/// Minimalist, monolithic "Моя волна" view.
/// Seamlessly integrated with the background, eliminating visual noise and floating boxes.
/// Features a unified now-playing banner, high-contrast vibe chips, and smooth queue listing.
/// Does NOT auto-play on navigation.
public struct MyWaveView: View {
    @UIState private var waveTracks: [YMTrack] = []
    @UIState private var rotorService = RotorService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var likesService = LikesService.shared
    @UIState private var authService = AuthService.shared

    @UIState private var isLoadingWave = false
    @UIState private var isLoadingMoreWave = false
    @UIState private var errorMessage: String? = nil
    @UIState private var toastMessage: String? = nil
    @UIState private var toastDismissTask: Task<Void, Never>? = nil
    @UIState private var waveStartTask: Task<Void, Never>? = nil

    @UIState private var isFlameActive: Bool = false
    @UIState private var wavePulse: CGFloat = 1.0

    public init() {}

    private var displayedWaveTracks: [YMTrack] {
        if audioEngine.isWaveMode && !audioEngine.queue.isEmpty {
            return audioEngine.queue
        }
        return waveTracks
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                // Top Header & Monolithic Hero Banner
                headerAndHeroSection

                if let user = authService.currentUser, !user.hasActiveSubscription {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundColor(YMTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Требуется подписка Яндекс Плюс")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YMTheme.fg)
                            Text("Для прослушивания Моей волны необходим активный Плюс")
                                .font(.system(size: 11))
                                .foregroundStyle(YMTheme.fg60)
                        }
                        Spacer()
                        Button("Оформить") {
                            if let url = URL(string: "https://plus.yandex.ru/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(YMTheme.surfaceComponent)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YMTheme.border, lineWidth: 1))
                    )
                    .padding(.horizontal, 24)
                }

                // Minimalist Vibe Presets
                vibePresetsSelector

                // Tuning Feedback Toast
                if let toast = toastMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundColor(YMTheme.accent)
                            .font(.system(size: 12, weight: .bold))
                        Text(toast)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(YMTheme.fg)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(YMTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                            .shadow(color: YMTheme.shadowColor, radius: 8, y: 2)
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
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.orange.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
                    )
                    .padding(.horizontal, 24)
                }

                // Upcoming Queue: "Далее в волне"
                upcomingQueueSection
            }
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
        .ymScreenBackground()
        .onAppear {
            // NEVER auto-start playback on navigation
            if audioEngine.isWaveMode && !audioEngine.queue.isEmpty {
                waveTracks = audioEngine.queue
            }
            setupWaveChangeHooks()
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                wavePulse = 1.1
            }
        }
    }

    // MARK: - Header & Monolithic Hero Section

    @ViewBuilder
    private var headerAndHeroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Screen Title & Subtitle
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Моя волна")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)

                        if audioEngine.isWaveMode {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(YMTheme.accent)
                                    .frame(width: 6, height: 6)
                                Text("в эфире")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(YMTheme.accent)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(YMTheme.accent.opacity(0.15)))
                        }
                    }

                    Text(audioEngine.activeWaveContext.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                }

                Spacer()

                if audioEngine.activeWaveContext != .myWaveDefault {
                    Button {
                        startWave(context: .myWaveDefault, vibe: audioEngine.activeWaveVibe)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                            Text("К обычной волне")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 30))
                }
            }

            // Monolithic Now-Playing / Ready Card (Blends seamlessly with the background)
            ZStack {
                // Subtle ambient gradient bleed (low opacity, soft radius)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(YMTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(YMTheme.border, lineWidth: 1)
                    )
                    .shadow(color: YMTheme.shadowColor, radius: 10, y: 3)

                if let track = audioEngine.currentTrack, audioEngine.isWaveMode {
                    activeTrackBanner(track: track)
                } else {
                    idleTrackBanner
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Active Track Banner (Seamlessly Merged)

    @ViewBuilder
    private func activeTrackBanner(track: YMTrack) -> some View {
        HStack(spacing: 16) {
            // Album Cover with animated equalizer
            Button {
                if let album = track.albums.first {
                    coordinator.navigate(to: .album(id: album.id, title: album.title))
                }
            } label: {
                ZStack {
                    CachedCoverImage(
                        coverUri: track.effectiveCoverUri,
                        size: .medium,
                        displaySize: 76,
                        cornerRadius: 10
                    )

                    if audioEngine.isPlaying {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 76, height: 76)

                        YMPlayingEqualizerView(
                            color: YMTheme.accent,
                            barWidth: 3,
                            maxHeight: 22,
                            isPlaying: true
                        )
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .help("Перейти к альбому")

            // Title, Artist and AI context
            VStack(alignment: .leading, spacing: 4) {
                Text(track.displayTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(YMTheme.fg)
                    .lineLimit(1)

                Button {
                    if let firstArtist = track.artists.first {
                        coordinator.navigate(to: .artist(id: firstArtist.id, name: firstArtist.name))
                    }
                } label: {
                    Text(track.artistsString)
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Перейти к исполнителю")

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(YMTheme.accent)
                    Text(aiInsightText(for: track))
                        .font(.system(size: 11))
                        .foregroundStyle(YMTheme.fg40)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            // Inline Playback & Wave Controls
            HStack(spacing: 12) {
                // Dislike
                Button {
                    audioEngine.applyWaveTuning(.lessLikeThis)
                    showToast("Меньше таких треков в волне")
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                        .padding(8)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help("Меньше таких треков")

                // Previous
                Button {
                    audioEngine.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Предыдущий трек")

                // Signature Yellow Play/Pause Disc (44x44 pt)
                Button {
                    audioEngine.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(YMTheme.accentFill)
                            .frame(width: 44, height: 44)
                            .shadow(color: YMTheme.accentFill.opacity(audioEngine.isPlaying ? 0.35 : 0.15), radius: 8, y: 2)

                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(Color.black)
                            .offset(x: audioEngine.isPlaying ? 0 : 1)
                    }
                }
                .buttonStyle(.plain)
                .help(audioEngine.isPlaying ? "Пауза" : "Воспроизведение")

                // Next
                Button {
                    audioEngine.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg80)
                        .padding(6)
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
                        .font(.system(size: 13))
                        .foregroundStyle(isFlameActive ? Color.orange : YMTheme.accent)
                        .padding(8)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help("Больше таких треков")

                // Like (Heart)
                Button {
                    Task {
                        await likesService.toggleLike(track: track)
                    }
                } label: {
                    Image(systemName: likesService.isLiked(trackId: track.id) ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundColor(likesService.isLiked(trackId: track.id) ? YMTheme.heartRed : YMTheme.fg60)
                        .padding(8)
                        .background(Circle().fill(YMTheme.surfaceComponent))
                }
                .buttonStyle(.plain)
                .help("Мне нравится")
            }
        }
        .padding(14)
    }

    // MARK: - Idle Track Banner

    @ViewBuilder
    private var idleTrackBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(YMTheme.surfaceComponent)
                    .frame(width: 58, height: 58)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 24))
                    .foregroundStyle(YMTheme.accent)
                    .scaleEffect(wavePulse)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Волна готова к воспроизведению")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(YMTheme.fg)

                Text("Нажмите кнопку, чтобы запустить бесконечный поток рекомендаций")
                    .font(.system(size: 12))
                    .foregroundStyle(YMTheme.fg60)
            }

            Spacer()

            Button {
                startWave(context: audioEngine.activeWaveContext, vibe: audioEngine.activeWaveVibe)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("Слушать Мою волну")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 38))
        }
        .padding(16)
    }

    // MARK: - Minimalist Vibe Presets Selector (With Black Icon Contrast Fix)

    private var vibePresetsSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Характер звучания")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMTheme.fg80)

                Spacer()

                Button {
                    audioEngine.applyWaveTuning(.moreDiversity)
                    showToast("Перенастройка волны: добавлено больше открытий")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Встряхнуть поток")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(YMTheme.surfaceComponent))
                    .foregroundColor(YMTheme.fg60)
                }
                .buttonStyle(.plain)
                .help("Встряхнуть и добавить больше неожиданных треков")
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(YMWaveVibePreset.allCases) { preset in
                        let isSelected = audioEngine.activeWaveVibe == preset
                        Button {
                            audioEngine.activeWaveVibe = preset
                            if audioEngine.isWaveMode {
                                startWave(context: audioEngine.activeWaveContext, vibe: preset)
                            }
                            showToast("Характер волны: \(preset.title)")
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: preset.iconName)
                                    .font(.system(size: 12, weight: .bold))
                                    // CRITICAL: when selected, icon turns black so it NEVER blends with yellow background!
                                    .foregroundColor(isSelected ? Color.black : vibeColor(for: preset))

                                Text(preset.title)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? Color.black : YMTheme.fg)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(isSelected ? YMTheme.accentFill : YMTheme.surfaceComponent)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? YMTheme.accentFill : YMTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func vibeColor(for preset: YMWaveVibePreset) -> Color {
        switch preset {
        case .defaultWave: return YMTheme.accent
        case .energetic: return Color(red: 0, green: 190 / 255, blue: 125 / 255)
        case .unfamiliar: return Color(red: 235 / 255, green: 130 / 255, blue: 0)
        case .familiar: return YMTheme.accent
        case .popular: return Color(red: 235 / 255, green: 60 / 255, blue: 60 / 255)
        case .calm: return Color(red: 150 / 255, green: 90 / 255, blue: 230 / 255)
        }
    }

    // MARK: - Upcoming Queue Section

    @ViewBuilder
    private var upcomingQueueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Далее в волне")
                        .font(.system(size: 18, weight: .bold))
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
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.1)
                    Text("Подбираем музыку для вашей волны...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
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
            return "Бодрый ритм под настроение"
        case .calm:
            return "Спокойная атмосфера для отдыха"
        case .unfamiliar:
            return "Свежее открытие на основе вкусов"
        case .familiar:
            return "Проверенный трек из любимых"
        case .popular:
            return "Популярный трек в Яндекс Музыке"
        case .defaultWave:
            return "Поток рекомендаций Моей волны"
        }
    }

    // MARK: - Wave Logic & Telemetry

    private func startWave(context: YMWaveContext, vibe: YMWaveVibePreset) {
        waveStartTask?.cancel()
        isLoadingWave = true
        errorMessage = nil

        waveStartTask = Task {
            do {
                let initialTracks = try await rotorService.startWave(context: context, vibe: vibe)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.waveTracks = initialTracks
                    self.isLoadingWave = false
                    self.audioEngine.activeWaveContext = context
                    self.audioEngine.activeWaveVibe = vibe
                    self.audioEngine.isWaveMode = true
                    self.audioEngine.setQueue(initialTracks, startingAt: 0)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoadingWave = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadMoreTracks() async {
        let currentList = displayedWaveTracks
        guard !isLoadingMoreWave, let lastTrack = currentList.last else { return }
        isLoadingMoreWave = true
        defer { isLoadingMoreWave = false }

        let history = Array(currentList.suffix(25)).map(\.rotorTrackIdentifier)
        do {
            let nextBatch = try await rotorService.fetchNextBatch(
                lastTrackId: lastTrack.rotorTrackIdentifier,
                queueHistory: history
            )
            guard !nextBatch.isEmpty else { return }
            if audioEngine.isWaveMode {
                audioEngine.appendToQueue(nextBatch)
                waveTracks = audioEngine.queue
            } else {
                waveTracks.append(contentsOf: nextBatch)
            }
        } catch {
            print("[MyWaveView] Error loading more wave tracks: \(error)")
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
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            toastMessage = message
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.toastMessage = nil
                }
            }
        }
    }
}
