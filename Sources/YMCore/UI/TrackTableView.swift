import SwiftUI

/// Modern native macOS track list with smooth lazy rendering, column headers,
/// interactive hover cards, and seamless context menus.
public struct TrackTableView: View {
    public let tracks: [YMTrack]
    public let onPlayTrack: (YMTrack) -> Void
    public var onTrackAppear: ((YMTrack) -> Void)? = nil
    public var onLoadMore: (() -> Void)? = nil
    public var showHeader: Bool = true
    public var showAlbum: Bool = true

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var likesService = LikesService.shared
    @UIState private var coordinator = NavigationCoordinator.shared

    public init(
        tracks: [YMTrack],
        onPlayTrack: @escaping (YMTrack) -> Void,
        onTrackAppear: ((YMTrack) -> Void)? = nil,
        onLoadMore: (() -> Void)? = nil,
        showHeader: Bool = true,
        showAlbum: Bool = true
    ) {
        self.tracks = tracks
        self.onPlayTrack = onPlayTrack
        self.onTrackAppear = onTrackAppear
        self.onLoadMore = onLoadMore
        self.showHeader = showHeader
        self.showAlbum = showAlbum
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showHeader && !tracks.isEmpty {
                headerView
                Divider()
                    .overlay(YMTheme.border)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    ModernTrackRow(
                        track: track,
                        index: index,
                        isPlaying: audioEngine.currentTrack?.id == track.id && audioEngine.isPlaying,
                        showAlbum: showAlbum,
                        onPlay: {
                            onPlayTrack(track)
                        },
                        onArtistSelect: { artist in
                            coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                        },
                        onAlbumSelect: { album in
                            coordinator.navigate(to: .album(id: album.id, title: album.title))
                        }
                    )
                    .onAppear {
                        onTrackAppear?(track)
                        if index >= tracks.count - 6 {
                            onLoadMore?()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        HStack(spacing: 12) {
            Text("#")
                .frame(width: 36, alignment: .center)

            Text("ТРЕК")
                .frame(minWidth: 200, alignment: .leading)

            Spacer()

            if showAlbum {
                Text("АЛЬБОМ")
                    .frame(width: 180, alignment: .leading)
            }

            Color.clear
                .frame(width: 32)

            Text("ВРЕМЯ")
                .frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(YMTheme.fg40)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Modern Track Row

private struct ModernTrackRow: View {
    let track: YMTrack
    let index: Int
    let isPlaying: Bool
    let showAlbum: Bool
    let onPlay: () -> Void
    let onArtistSelect: (YMArtist) -> Void
    let onAlbumSelect: (YMAlbum) -> Void

    @UIState private var likesService = LikesService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var isHovered = false
    @UIState private var hoverTask: Task<Void, Never>? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Track Number (clean & simple, animation is on the cover only)
            Text("\(index + 1)")
                .font(.system(size: 12, weight: isPlaying ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isPlaying ? YMTheme.accent : YMTheme.fg40)
                .frame(width: 36, alignment: .center)

            // Cover thumbnail with hover play button & animated playing state
            ZStack {
                CachedCoverImage(
                    coverUri: track.effectiveCoverUri,
                    size: .small,
                    displaySize: 40,
                    cornerRadius: 6
                )

                if isPlaying {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.55))
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
                    .help("Воспроизвести трек")
                }
            }
            .frame(width: 40, height: 40)

            // Title & Artists
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: isPlaying ? .bold : .medium))
                    .foregroundStyle(isPlaying ? YMTheme.accent : YMTheme.fg)
                    .lineLimit(1)

                if !track.artists.isEmpty {
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
                } else {
                    Text(track.artistsString)
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Album
            if showAlbum {
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

            // Like Heart Button
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
            .help(likesService.isLiked(trackId: track.id) ? "Удалить из Мне нравится" : "Мне нравится")

            // Duration
            Text(track.formattedDuration)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(YMTheme.fg40)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPlaying ? YMTheme.surfaceComponentHover : (isHovered ? YMTheme.surfaceComponent : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    // Fast responsive hover with light debounce during rapid scroll
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.08)) {
                            isHovered = true
                        }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.08)) {
                    isHovered = false
                }
            }
        }
        .onTapGesture(count: 2) {
            onPlay()
        }
        .contextMenu {
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
            Button("Показать текст песни") {
                coordinator.showLyrics(for: track)
            }
            Divider()
            Button(likesService.isLiked(trackId: track.id) ? "Удалить из Мне нравится" : "Добавить в Мне нравится") {
                Task {
                    await likesService.toggleLike(track: track)
                }
            }
        }
    }
}
