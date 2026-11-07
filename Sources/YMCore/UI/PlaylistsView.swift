import SwiftUI

/// Modern Playlists view supporting responsive grid of playlist cards and deep-dive playlist detail view.
public struct PlaylistsView: View {
    @UIState private var playlists: [YMPlaylist] = []
    @UIState private var selectedPlaylist: YMPlaylist? = nil
    @UIState private var playlistTracks: [YMTrack] = []
    @UIState private var isLoadingPlaylists = false
    @UIState private var isLoadingTracks = false
    @UIState private var errorMessage: String? = nil
    @UIState private var playlistFilterQuery: String = ""
    @UIState private var playlistDetailTask: Task<Void, Never>? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared
    private let keychain = KeychainManager.shared

    private var displayedPlaylistTracks: [YMTrack] {
        let q = playlistFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return playlistTracks }
        return playlistTracks.filter { track in
            track.displayTitle.lowercased().contains(q) ||
            track.artistsString.lowercased().contains(q) ||
            (track.primaryAlbumTitle?.lowercased().contains(q) ?? false)
        }
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            if let playlist = selectedPlaylist {
                playlistDetailView(playlist: playlist)
            } else {
                playlistsGridView
            }
        }
        .ymScreenBackground()
        .task {
            if playlists.isEmpty {
                loadPlaylists()
            }
        }
    }

    // MARK: - Playlists Grid View

    private var playlistsGridView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Плейлисты")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)

                        Text("Ваша коллекция плейлистов и подборки")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                    }

                    Spacer()

                    Button {
                        loadPlaylists()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Обновить")
                        }
                    }
                    .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
                    .disabled(isLoadingPlaylists)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Divider()
                    .padding(.horizontal, 24)

                if let error = errorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Повторить") {
                            loadPlaylists()
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    .padding(.horizontal, 24)
                }

                if isLoadingPlaylists && playlists.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Загрузка ваших плейлистов...")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else if playlists.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 44))
                            .foregroundStyle(YMTheme.fg40)
                        Text("Плейлисты не найдены")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                        Text("Созданные вами плейлисты в Яндекс Музыке появятся здесь")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    let cardSize: CGFloat = windowState.isCompactWidth ? 140 : 160
                    let spacing: CGFloat = 20
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: 200), spacing: spacing)], spacing: spacing) {
                        ForEach(playlists) { playlist in
                            PlaylistCardItem(
                                playlist: playlist,
                                cardSize: cardSize,
                                onSelect: {
                                    selectPlaylist(playlist)
                                },
                                onPlay: {
                                    playPlaylistImmediately(playlist, shuffle: false, startWave: false)
                                },
                                onShuffle: {
                                    playPlaylistImmediately(playlist, shuffle: true, startWave: false)
                                },
                                onWave: {
                                    playPlaylistImmediately(playlist, shuffle: false, startWave: true)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 60)
        }
    }

    // MARK: - Playlist Detail View

    private func playlistDetailView(playlist: YMPlaylist) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // Top Navigation Bar
                HStack(spacing: 12) {
                    Button {
                        playlistDetailTask?.cancel()
                        selectedPlaylist = nil
                        playlistTracks = []
                        playlistFilterQuery = ""
                        errorMessage = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Все плейлисты")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(YMTheme.surfaceComponent))
                        .overlay(Capsule().strokeBorder(YMTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Text(playlist.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(YMTheme.fg60)

                    Spacer()
                }
                .padding(.top, 16)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                // Playlist Hero Header
                HStack(alignment: .bottom, spacing: 24) {
                    CachedCoverImage(
                        coverUri: playlist.coverUri,
                        size: .large,
                        displaySize: 150,
                        cornerRadius: YMTheme.cornerRadiusMedium
                    )
                    .frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ПЛЕЙЛИСТ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(YMTheme.fg40)
                            .tracking(1.2)

                        Text(playlist.title)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(2)

                        if let count = playlist.trackCount {
                            Text("\(count) треков")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(YMTheme.fg60)
                        }

                        // Actions
                        HStack(spacing: 12) {
                            Button {
                                audioEngine.isWaveMode = false
                                audioEngine.setQueue(displayedPlaylistTracks, startingAt: 0)
                            } label: {
                                Label("Слушать всё", systemImage: "play.fill")
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 34))
                            .disabled(displayedPlaylistTracks.isEmpty)

                            Button {
                                audioEngine.playShuffled(displayedPlaylistTracks)
                            } label: {
                                Label("Перемешать", systemImage: "shuffle")
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 34))
                            .disabled(displayedPlaylistTracks.isEmpty)

                            Button {
                                audioEngine.startWave(forPlaylist: playlist, tracks: playlistTracks)
                            } label: {
                                Label("Волна по плейлисту", systemImage: "waveform.path.ecg")
                            }
                            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 34))
                            .disabled(playlistTracks.isEmpty)
                        }
                        .padding(.top, 4)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                // Filter Bar inside playlist
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg40)

                    TextField("Поиск по названиям треков и артистам...", text: $playlistFilterQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if !playlistFilterQuery.isEmpty {
                        Button {
                            playlistFilterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(YMTheme.fg40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(YMTheme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                Divider()
                    .overlay(YMTheme.border)
                    .padding(.horizontal, 24)

                if isLoadingTracks && playlistTracks.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Загрузка треков...")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if displayedPlaylistTracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.system(size: 36))
                            .foregroundStyle(YMTheme.fg40)
                        Text(playlistFilterQuery.isEmpty ? "В плейлисте нет треков" : "Ничего не найдено по запросу")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    TrackTableView(
                        tracks: displayedPlaylistTracks,
                        onPlayTrack: { track in
                            audioEngine.isWaveMode = false
                            if let idx = displayedPlaylistTracks.firstIndex(where: { $0.id == track.id }) {
                                audioEngine.setQueue(displayedPlaylistTracks, startingAt: idx)
                            }
                        }
                    )
                    .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 80)
        }
    }

    // MARK: - Actions & Loading

    private func loadPlaylists() {
        isLoadingPlaylists = true
        errorMessage = nil

        Task {
            guard let uid = AuthService.shared.currentUser?.userId ?? (try? keychain.getString(for: .userId)) else {
                await MainActor.run {
                    self.errorMessage = "Не удалось определить ID пользователя"
                    self.isLoadingPlaylists = false
                }
                return
            }

            do {
                let fetched = try await networkClient.fetchUserPlaylists(uid: uid)
                await MainActor.run {
                    self.playlists = fetched
                    self.isLoadingPlaylists = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoadingPlaylists = false
                }
            }
        }
    }

    private func selectPlaylist(_ playlist: YMPlaylist) {
        playlistDetailTask?.cancel()
        selectedPlaylist = playlist
        playlistTracks = []
        isLoadingTracks = true
        errorMessage = nil
        let targetPlaylistId = playlist.id

        playlistDetailTask = Task {
            do {
                let details = try await networkClient.fetchPlaylistDetails(uid: playlist.uid, kind: playlist.kind)
                var resolvedTracks: [YMTrack] = []
                if let detailedTracks = details.tracks, !detailedTracks.isEmpty {
                    resolvedTracks = detailedTracks.compactMap { $0.track }
                    if resolvedTracks.isEmpty {
                        let ids = detailedTracks.map { String($0.id) }
                        resolvedTracks = try await networkClient.fetchTracks(trackIds: ids)
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedPlaylist?.id == targetPlaylistId else { return }
                    self.playlistTracks = resolvedTracks
                    self.isLoadingTracks = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedPlaylist?.id == targetPlaylistId else { return }
                    self.errorMessage = "Не удалось загрузить плейлист: \(error.localizedDescription)"
                    self.isLoadingTracks = false
                }
            }
        }
    }

    private func playPlaylistImmediately(_ playlist: YMPlaylist, shuffle: Bool, startWave: Bool) {
        Task {
            do {
                let details = try await networkClient.fetchPlaylistDetails(uid: playlist.uid, kind: playlist.kind)
                var resolvedTracks: [YMTrack] = []
                if let detailedTracks = details.tracks, !detailedTracks.isEmpty {
                    resolvedTracks = detailedTracks.compactMap { $0.track }
                    if resolvedTracks.isEmpty {
                        let ids = detailedTracks.map { String($0.id) }
                        resolvedTracks = try await networkClient.fetchTracks(trackIds: ids)
                    }
                }

                guard !resolvedTracks.isEmpty else { return }

                await MainActor.run {
                    if startWave {
                        self.audioEngine.startWave(forPlaylist: playlist, tracks: resolvedTracks)
                    } else if shuffle {
                        self.audioEngine.playShuffled(resolvedTracks)
                    } else {
                        self.audioEngine.isWaveMode = false
                        self.audioEngine.setQueue(resolvedTracks, startingAt: 0)
                    }
                }
            } catch {
                print("[PlaylistsView] Failed to play: \(error)")
            }
        }
    }
}

// MARK: - Playlist Card Component

private struct PlaylistCardItem: View {
    let playlist: YMPlaylist
    let cardSize: CGFloat
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onWave: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        Button {
            onSelect()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    CachedCoverImage(
                        coverUri: playlist.coverUri,
                        size: .medium,
                        displaySize: cardSize,
                        cornerRadius: YMTheme.cornerRadiusMedium
                    )
                    .frame(width: cardSize, height: cardSize)
                    .ymCardHover(cornerRadius: YMTheme.cornerRadiusMedium, scale: 1.04)

                    if isHovered {
                        Button {
                            onPlay()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(YMTheme.accent))
                                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .onHover { isHovered = $0 }

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHovered ? YMTheme.accent : YMTheme.fg)
                        .lineLimit(1)

                    if let count = playlist.trackCount {
                        Text("\(count) треков")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                }
                .frame(width: cardSize, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Слушать плейлист", action: onPlay)
            Button("Перемешать", action: onShuffle)
            Button("Запустить волну по плейлисту", action: onWave)
        }
    }
}
