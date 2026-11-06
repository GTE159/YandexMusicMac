import SwiftUI

/// Chart (Чарт) view showing the Top 100 most popular tracks in Yandex Music with positions, shifts, and rich actions.
public struct ChartView: View {
    @UIState private var chartItems: [YMChartItem] = []
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var likesService = LikesService.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared

    public init() {}

    private var chartTracks: [YMTrack] {
        chartItems.compactMap(\.track)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Header
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Чарт")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(YMTheme.fg)

                    Text("Топ треков, которые прямо сейчас слушают в Яндекс Музыке")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg60)
                }

                Spacer()

                if !chartTracks.isEmpty {
                    Button {
                        audioEngine.assignQueue(chartTracks, startingAt: 0)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                            Text("Слушать чарт")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 36))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Table Column Headers
            HStack(spacing: 12) {
                Text("#")
                    .frame(width: 44, alignment: .center)

                Text("ТРЕК")
                    .frame(minWidth: 200, alignment: .leading)

                Spacer()

                Text("АЛЬБОМ")
                    .frame(width: 180, alignment: .leading)

                Text("♡")
                    .frame(width: 32, alignment: .center)

                Text("ВРЕМЯ")
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(YMTheme.fg40)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            Divider()
                .overlay(YMTheme.border)
                .padding(.horizontal, 24)

            // Main Content
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Загрузка чарта...")
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Повторить") {
                        loadChart()
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(chartItems.enumerated()), id: \.element.id) { index, item in
                            if let track = item.track {
                                ChartTrackRow(
                                    item: item,
                                    track: track,
                                    index: index,
                                    isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.isPlaying,
                                    onPlay: {
                                        audioEngine.assignQueue(chartTracks, startingAt: index)
                                    },
                                    onArtistSelect: { artist in
                                        coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                                    },
                                    onAlbumSelect: { album in
                                        coordinator.navigate(to: .album(id: album.id, title: album.title))
                                    }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 90)
                }
            }
        }
        .ymScreenBackground()
        .task {
            if chartItems.isEmpty {
                loadChart()
            }
        }
    }

    private func loadChart() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let items = try await networkClient.fetchChart()
                await MainActor.run {
                    self.chartItems = items
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Не удалось загрузить чарт: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}

// MARK: - Chart Track Row

private struct ChartTrackRow: View {
    let item: YMChartItem
    let track: YMTrack
    let index: Int
    let isPlaying: Bool
    let onPlay: () -> Void
    let onArtistSelect: (YMArtist) -> Void
    let onAlbumSelect: (YMAlbum) -> Void

    @UIState private var likesService = LikesService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var isHovered = false
    @UIState private var hoverTask: Task<Void, Never>? = nil

    private var position: Int {
        item.chart?.position ?? (index + 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            rankView
            coverAndPlayView
            titleAndArtistsView
            Spacer()
            albumView
            likeButtonView
            durationView
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPlaying ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 90_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovered = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = false
                }
            }
        }
        .onTapGesture(count: 2) {
            onPlay()
        }
        .contextMenu {
            rowContextMenu
        }
    }

    @ViewBuilder
    private var rankView: some View {
        HStack(spacing: 3) {
            if position <= 3 {
                Text("\(position)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .foregroundColor(YMTheme.accent)
                    .frame(width: 22, alignment: .trailing)
            } else {
                Text("\(position)")
                    .font(.system(size: 13, weight: isPlaying ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isPlaying ? YMTheme.accent : YMTheme.fg60)
                    .frame(width: 22, alignment: .trailing)
            }

            shiftIndicator
                .frame(width: 14, alignment: .center)
        }
        .frame(width: 44)
    }

    @ViewBuilder
    private var coverAndPlayView: some View {
        ZStack {
            CachedCoverImage(
                coverUri: track.effectiveCoverUri,
                size: .small,
                displaySize: 40,
                cornerRadius: 6
            )

            if isPlaying {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 40, height: 40)

                if isHovered {
                    Button {
                        audioEngine.togglePlayPause()
                    } label: {
                        Image(systemName: audioEngine.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(YMTheme.accent)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help(audioEngine.isPlaying ? "Пауза" : "Воспроизвести")
                } else {
                    YMPlayingEqualizerView(color: YMTheme.accent, barWidth: 2.5, maxHeight: 15, isPlaying: audioEngine.isPlaying)
                }
            } else if isHovered {
                Button {
                    onPlay()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 40, height: 40)
                        Image(systemName: "play.fill")
                            .foregroundColor(Color.white)
                            .font(.system(size: 13))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 40, height: 40)
    }

    @ViewBuilder
    private var titleAndArtistsView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track.displayTitle)
                .font(.system(size: 13, weight: isPlaying ? .bold : .medium))
                .foregroundStyle(isPlaying ? YMTheme.accent : YMTheme.fg)
                .lineLimit(1)

            HStack(spacing: 4) {
                ForEach(track.artists) { artist in
                    Button {
                        onArtistSelect(artist)
                    } label: {
                        Text(artist.name)
                            .font(.system(size: 12))
                            .foregroundStyle(YMTheme.fg60)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    if artist.id != track.artists.last?.id {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(YMTheme.fg40)
                    }
                }
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private var albumView: some View {
        if let album = track.albums.first {
            Button {
                onAlbumSelect(album)
            } label: {
                Text(album.title)
                    .font(.system(size: 12))
                    .foregroundStyle(YMTheme.fg60)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(width: 180, alignment: .leading)
        } else {
            Color.clear
                .frame(width: 180)
        }
    }

    @ViewBuilder
    private var likeButtonView: some View {
        Button {
            Task {
                await likesService.toggleLike(track: track)
            }
        } label: {
            Image(systemName: likesService.isLiked(trackId: track.id) ? "heart.fill" : "heart")
                .foregroundColor(likesService.isLiked(trackId: track.id) ? YMTheme.heartRed : YMTheme.fg40)
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .frame(width: 32, alignment: .center)
        .help(likesService.isLiked(trackId: track.id) ? "Удалить из Мне нравится" : "Нравится")
    }

    @ViewBuilder
    private var durationView: some View {
        Text(track.formattedDuration)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(YMTheme.fg40)
            .frame(width: 50, alignment: .trailing)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button("Воспроизвести сейчас") {
            onPlay()
        }
        Button("Воспроизвести следующим") {
            audioEngine.insertNext(track)
        }
        Button("Добавить в конец очереди") {
            audioEngine.addToQueue([track])
        }
        Divider()
        Button("Запустить Мою волну по треку") {
            audioEngine.startWave(forTrack: track)
        }
        if let artist = track.artists.first {
            Button("Перейти к исполнителю: \(artist.name)") {
                onArtistSelect(artist)
            }
        }
        if let album = track.albums.first {
            Button("Перейти к альбому: \(album.title)") {
                onAlbumSelect(album)
            }
        }
        Divider()
        Button(likesService.isLiked(trackId: track.id) ? "Удалить из Мне нравится" : "Добавить в Мне нравится") {
            Task {
                await likesService.toggleLike(track: track)
            }
        }
    }

    @ViewBuilder
    private var shiftIndicator: some View {
        if let chart = item.chart {
            switch chart.progress {
            case "up":
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.green)
            case "down":
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7))
                    .rotationEffect(.degrees(180))
                    .foregroundColor(.red)
            case "new":
                Text("★")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange)
            default:
                Text("•")
                    .font(.system(size: 8))
                    .foregroundStyle(YMTheme.fg40)
            }
        }
    }
}
