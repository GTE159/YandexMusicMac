import SwiftUI

fileprivate func formatTrackCount(_ count: Int) -> String {
    let mod10 = count % 10
    let mod100 = count % 100
    if mod100 >= 11 && mod100 <= 19 {
        return "\(count) треков"
    }
    switch mod10 {
    case 1:
        return "\(count) трек"
    case 2, 3, 4:
        return "\(count) трека"
    default:
        return "\(count) треков"
    }
}

/// Modern Playlists view supporting responsive grid of playlist cards and deep-dive playlist detail view.
public struct PlaylistsView: View {
    @UIState private var playlistsService = PlaylistsService.shared
    @UIState private var selectedPlaylist: YMPlaylist? = nil
    @UIState private var playlistTracks: [YMTrack] = []
    @UIState private var cachedDisplayedPlaylistTracks: [YMTrack] = []
    @UIState private var isLoadingTracks = false
    @UIState private var detailErrorMessage: String? = nil
    @UIState private var playlistFilterQuery: String = ""
    @UIState private var playlistDetailTask: Task<Void, Never>? = nil
    @UIState private var quickPlayTask: Task<Void, Never>? = nil
    @UIState private var isGridScrolled = false
    @UIState private var isDetailScrolled = false

    @UIState private var isCreateSheetPresented = false
    @UIState private var playlistBeingEdited: YMPlaylist? = nil
    @UIState private var playlistPendingDelete: YMPlaylist? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    private let networkClient = YMNetworkClient.shared

    private var playlists: [YMPlaylist] {
        playlistsService.playlists
    }

    private var isLoadingPlaylists: Bool {
        playlistsService.isLoading
    }

    private var displayedPlaylistTracks: [YMTrack] {
        cachedDisplayedPlaylistTracks
    }

    private func updateCachedDisplayedTracks() {
        let q = playlistFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            cachedDisplayedPlaylistTracks = playlistTracks
            return
        }
        cachedDisplayedPlaylistTracks = playlistTracks.filter { track in
            track.displayTitle.localizedCaseInsensitiveContains(q) ||
            track.artists.contains { $0.name.localizedCaseInsensitiveContains(q) } ||
            (track.artists.isEmpty && track.artistsString.localizedCaseInsensitiveContains(q)) ||
            (track.primaryAlbumTitle?.localizedCaseInsensitiveContains(q) ?? false)
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
        .sheet(isPresented: $isCreateSheetPresented) {
            PlaylistEditorSheet(
                editingPlaylist: nil,
                initialTracks: [],
                onDismiss: {
                    isCreateSheetPresented = false
                },
                onSaved: { created in
                    isCreateSheetPresented = false
                    selectPlaylist(created)
                }
            )
        }
        .sheet(item: $playlistBeingEdited) { target in
            PlaylistEditorSheet(
                editingPlaylist: target,
                initialTracks: [],
                onDismiss: {
                    playlistBeingEdited = nil
                },
                onSaved: { updated in
                    playlistBeingEdited = nil
                    if selectedPlaylist?.id == updated.id {
                        selectedPlaylist = updated
                    }
                }
            )
        }
        .alert(
            "Удалить плейлист?",
            isPresented: Binding(
                get: { playlistPendingDelete != nil },
                set: { if !$0 { playlistPendingDelete = nil } }
            ),
            presenting: playlistPendingDelete
        ) { target in
            Button("Удалить", role: .destructive) {
                deletePlaylistConfirmed(target)
            }
            Button("Отмена", role: .cancel) {
                playlistPendingDelete = nil
            }
        } message: { target in
            Text("Плейлист «\(target.title)» будет безвозвратно удалён из вашего аккаунта Яндекс Музыки.")
        }
        .task {
            await playlistsService.ensureLoaded()
        }
        .onDisappear {
            playlistDetailTask?.cancel()
            playlistDetailTask = nil
            quickPlayTask?.cancel()
            quickPlayTask = nil
        }
        .onChange(of: playlistFilterQuery) { _, _ in
            updateCachedDisplayedTracks()
        }
        .onChange(of: playlistTracks) { _, _ in
            updateCachedDisplayedTracks()
        }
    }

    // MARK: - Playlists Grid View

    private var playlistsGridView: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // Header (adaptive for narrow windows)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        playlistsTitleBlock
                        Spacer(minLength: 12)
                        playlistsHeaderActions(compact: false)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        playlistsTitleBlock
                        playlistsHeaderActions(compact: true)
                    }
                }
                .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                .padding(.top, windowState.topChromeContentPadding)

                Divider()
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)

                if let error = playlistsService.errorMessage {
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
                        Text("Создайте свой первый плейлист прямо здесь или добавьте подборки в Яндекс Музыке")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        Button {
                            isCreateSheetPresented = true
                        } label: {
                            Label("Создать плейлист", systemImage: "plus")
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 34))
                        .padding(.top, 4)
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
                                },
                                onEdit: {
                                    playlistBeingEdited = playlist
                                },
                                onDelete: {
                                    playlistPendingDelete = playlist
                                }
                            )
                        }
                    }
                    .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                }
            }
            .padding(.bottom, 60)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "playlists_grid_scroll",
                        threshold: 52,
                        isScrolled: $isGridScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 52, isScrolled: $isGridScrolled)
        .coordinateSpace(name: "playlists_grid_scroll")
        .overlay(alignment: .top) {
            YMStickyTopBar(title: "Плейлисты", isVisible: isGridScrolled)
        }
    }

    @ViewBuilder
    private var playlistsTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Плейлисты")
                .font(.system(size: windowState.isCompactWidth ? 24 : 28, weight: .bold))
                .foregroundStyle(YMTheme.fg)

            Text("Ваша коллекция плейлистов и подборки")
                .font(.subheadline)
                .foregroundStyle(YMTheme.fg60)
        }
    }

    @ViewBuilder
    private func playlistsHeaderActions(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                isCreateSheetPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text(compact ? "Создать" : "Создать плейлист")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 32))

            Button {
                loadPlaylists()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    if !compact {
                        Text("Обновить")
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 32))
            .disabled(isLoadingPlaylists)
            .help("Обновить список плейлистов")
        }
    }

    // MARK: - Playlist Detail View

    private func playlistDetailView(playlist: YMPlaylist) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // Playlist Hero Header with atmospheric cover glow
                let coverSize: CGFloat = windowState.isMiniWidth ? 80 : (windowState.isCompactWidth ? 96 : 150)
                HStack(alignment: .bottom, spacing: windowState.isCompactWidth ? 16 : 24) {
                    CachedCoverImage(
                        coverUri: playlist.coverUri,
                        size: .large,
                        displaySize: coverSize,
                        cornerRadius: YMTheme.cornerRadiusLarge
                    )
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: YMTheme.shadowColor, radius: 18, y: 8)

                    VStack(alignment: .leading, spacing: windowState.isCompactWidth ? 6 : 8) {
                        HStack(spacing: 8) {
                            Text("ПЛЕЙЛИСТ")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(YMTheme.fg40)
                                .tracking(1.2)

                            if playlist.isPrivate {
                                HStack(spacing: 3) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                    Text("Приватный")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(YMTheme.fg60)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(YMTheme.surfaceComponent))
                            }
                        }

                        Text(playlist.title)
                            .font(.system(size: windowState.isCompactWidth ? 22 : 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(2)

                        if let desc = playlist.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 13))
                                .foregroundStyle(YMTheme.fg80)
                                .lineLimit(3)
                        }

                        let effectiveCount = playlistTracks.isEmpty ? (playlist.trackCount ?? 0) : playlistTracks.count
                        Text(formatTrackCount(effectiveCount))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(YMTheme.fg60)
                            .lineLimit(1)

                        // Adaptive Actions Bar
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                playlistPlayButton(title: "Слушать всё", height: 34)
                                playlistShuffleButton(title: "Перемешать", height: 34)
                                playlistWaveButton(playlist: playlist, title: "Волна по плейлисту", height: 34)
                                BatchDownloadButton(tracks: playlistTracks, height: 34, compact: false)
                                playlistEditButton(playlist: playlist, height: 34)
                                playlistDeleteButton(playlist: playlist, height: 34)
                            }

                            HStack(spacing: 8) {
                                playlistPlayButton(title: "Слушать", height: 30)
                                playlistShuffleButton(title: "Микс", height: 30)
                                playlistWaveButton(playlist: playlist, title: "Волна", height: 30)
                                BatchDownloadButton(tracks: playlistTracks, height: 30, compact: true)
                                playlistEditButton(playlist: playlist, height: 30)
                                playlistDeleteButton(playlist: playlist, height: 30)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    playlistPlayButton(title: "Слушать", height: 30)
                                    playlistShuffleButton(title: "Микс", height: 30)
                                    BatchDownloadButton(tracks: playlistTracks, height: 30, compact: true)
                                    playlistEditButton(playlist: playlist, height: 30)
                                    playlistDeleteButton(playlist: playlist, height: 30)
                                }
                                playlistWaveButton(playlist: playlist, title: "Волна по плейлисту", height: 30)
                            }
                        }
                        .padding(.top, 4)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                .padding(.top, 52)
                .padding(.bottom, 16)
                .ymAmbientCoverGlow(coverUri: playlist.coverUri, opacity: 0.24)

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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(YMTheme.surfaceComponent)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                Divider()
                    .overlay(YMTheme.border)
                    .padding(.horizontal, 24)

                if let detailError = detailErrorMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(detailError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                }

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
                        Text(playlistFilterQuery.isEmpty ? "В плейлисте пока нет треков" : "Ничего не найдено по запросу")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                        if playlistFilterQuery.isEmpty {
                            Text("Нажмите правой кнопкой на любой трек в приложении и выберите «Добавить в плейлист»")
                                .font(.subheadline)
                                .foregroundStyle(YMTheme.fg60)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 28)
                        }
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
                        },
                        onRemoveFromPlaylist: { track, displayedIdx in
                            removeTrackFromSelectedPlaylist(track: track, displayedIdx: displayedIdx, playlist: playlist)
                        }
                    )
                    .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 80)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "playlist_detail_scroll",
                        threshold: 84,
                        isScrolled: $isDetailScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 84, isScrolled: $isDetailScrolled)
        .coordinateSpace(name: "playlist_detail_scroll")
        .overlay(alignment: .top) {
            YMStickyDetailTopBar(
                backTitle: "Все плейлисты",
                title: playlist.title,
                isScrolled: isDetailScrolled
            ) {
                playlistDetailTask?.cancel()
                selectedPlaylist = nil
                playlistTracks = []
                playlistFilterQuery = ""
                detailErrorMessage = nil
                isDetailScrolled = false
            }
        }
    }

    @ViewBuilder
    private func playlistPlayButton(title: String, height: CGFloat) -> some View {
        Button {
            audioEngine.isWaveMode = false
            audioEngine.setQueue(displayedPlaylistTracks, startingAt: 0)
        } label: {
            Label(title, systemImage: "play.fill")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: height))
        .disabled(displayedPlaylistTracks.isEmpty)
    }

    @ViewBuilder
    private func playlistShuffleButton(title: String, height: CGFloat) -> some View {
        Button {
            audioEngine.playShuffled(displayedPlaylistTracks)
        } label: {
            Label(title, systemImage: "shuffle")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(displayedPlaylistTracks.isEmpty)
    }

    @ViewBuilder
    private func playlistWaveButton(playlist: YMPlaylist, title: String, height: CGFloat) -> some View {
        Button {
            audioEngine.startWave(forPlaylist: playlist, tracks: playlistTracks)
        } label: {
            Label(title, systemImage: "waveform.path.ecg")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(playlistTracks.isEmpty)
    }

    @ViewBuilder
    private func playlistEditButton(playlist: YMPlaylist, height: CGFloat) -> some View {
        Button {
            playlistBeingEdited = playlist
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12.5, weight: .semibold))
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .help("Изменить название, описание или приватность")
    }

    @ViewBuilder
    private func playlistDeleteButton(playlist: YMPlaylist, height: CGFloat) -> some View {
        Button {
            playlistPendingDelete = playlist
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.85))
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .help("Удалить плейлист")
    }

    // MARK: - Actions & Loading

    private func loadPlaylists() {
        Task {
            await playlistsService.loadPlaylists(force: true)
        }
    }

    private func deletePlaylistConfirmed(_ playlist: YMPlaylist) {
        playlistPendingDelete = nil
        Task {
            do {
                try await playlistsService.deletePlaylist(playlist)
                if selectedPlaylist?.id == playlist.id {
                    playlistDetailTask?.cancel()
                    selectedPlaylist = nil
                    playlistTracks = []
                    playlistFilterQuery = ""
                    detailErrorMessage = nil
                    isDetailScrolled = false
                }
                playlistsService.showToast("Плейлист «\(playlist.title)» удалён")
            } catch {
                detailErrorMessage = "Не удалось удалить плейлист: \(error.localizedDescription)"
                playlistsService.showToast("Ошибка удаления плейлиста")
            }
        }
    }

    private func removeTrackFromSelectedPlaylist(track: YMTrack, displayedIdx: Int, playlist: YMPlaylist) {
        let isFilterEmpty = playlistFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let originalIdx: Int
        if isFilterEmpty && displayedIdx < playlistTracks.count && playlistTracks[displayedIdx].id == track.id {
            originalIdx = displayedIdx
        } else if let foundIdx = playlistTracks.firstIndex(where: { $0.id == track.id }) {
            originalIdx = foundIdx
        } else {
            return
        }
        let removedTrack = playlistTracks.remove(at: originalIdx)
        updateCachedDisplayedTracks()
        Task {
            do {
                let updated = try await playlistsService.removeTrack(track, at: originalIdx, from: playlist)
                if selectedPlaylist?.id == updated.id {
                    selectedPlaylist = updated
                }
                playlistsService.showToast("Трек удалён из «\(playlist.title)»")
            } catch {
                // Rollback optimistic removal on failure
                let insertIdx = min(originalIdx, playlistTracks.count)
                playlistTracks.insert(removedTrack, at: insertIdx)
                updateCachedDisplayedTracks()
                detailErrorMessage = "Не удалось удалить трек: \(error.localizedDescription)"
            }
        }
    }

    private func selectPlaylist(_ playlist: YMPlaylist) {
        playlistDetailTask?.cancel()
        isDetailScrolled = false
        selectedPlaylist = playlist
        playlistTracks = []
        cachedDisplayedPlaylistTracks = []
        isLoadingTracks = true
        detailErrorMessage = nil
        let targetPlaylistId = playlist.id

        playlistDetailTask = Task {
            do {
                let details = try await networkClient.fetchPlaylistDetails(uid: playlist.uid, kind: playlist.kind)
                let resolvedTracks = try await resolveAllTracks(from: details.tracks ?? [])

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedPlaylist?.id == targetPlaylistId else { return }
                    self.selectedPlaylist = details
                    self.playlistsService.upsertPlaylist(details, insertAtTop: false)
                    self.playlistTracks = resolvedTracks
                    self.updateCachedDisplayedTracks()
                    self.isLoadingTracks = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedPlaylist?.id == targetPlaylistId else { return }
                    self.detailErrorMessage = "Не удалось загрузить плейлист: \(error.localizedDescription)"
                    self.isLoadingTracks = false
                }
            }
        }
    }

    private func resolveAllTracks(from detailedTracks: [YMTrackShort]) async throws -> [YMTrack] {
        guard !detailedTracks.isEmpty else { return [] }
        let missingIds = detailedTracks.compactMap { $0.track == nil ? String($0.id) : nil }
        if missingIds.isEmpty {
            return detailedTracks.compactMap(\.track)
        }
        let fetchedMissing = try await networkClient.fetchTracks(trackIds: missingIds)
        var fetchedById: [String: YMTrack] = [:]
        for track in fetchedMissing {
            fetchedById[track.id] = track
            if let colon = track.id.firstIndex(of: ":") {
                fetchedById[String(track.id[..<colon])] = track
            }
        }
        return detailedTracks.compactMap { short in
            if let direct = short.track { return direct }
            let cleanId = short.id.components(separatedBy: ":").first ?? short.id
            return fetchedById[short.id] ?? fetchedById[cleanId]
        }
    }

    private func playPlaylistImmediately(_ playlist: YMPlaylist, shuffle: Bool, startWave: Bool) {
        quickPlayTask?.cancel()
        quickPlayTask = Task {
            do {
                let details = try await networkClient.fetchPlaylistDetails(uid: playlist.uid, kind: playlist.kind)
                let resolvedTracks = try await resolveAllTracks(from: details.tracks ?? [])

                guard !Task.isCancelled, !resolvedTracks.isEmpty else { return }

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
                if !Task.isCancelled {
                    print("[PlaylistsView] Failed to play: \(error)")
                }
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    @UIState private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    CachedCoverImage(
                        coverUri: playlist.coverUri,
                        size: .medium,
                        displaySize: cardSize,
                        cornerRadius: YMTheme.cornerRadiusMedium
                    )
                    .scaleEffect(isHovered ? 1.05 : 1.0)

                    if isHovered {
                        LinearGradient(
                            colors: [Color.clear, Color.black.opacity(0.42)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: cardSize, height: cardSize)
                .clipShape(RoundedRectangle(cornerRadius: YMTheme.cornerRadiusMedium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMTheme.cornerRadiusMedium, style: .continuous)
                        .strokeBorder(isHovered ? YMTheme.borderHover : YMTheme.border, lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .shadow(
                    color: YMTheme.shadowColor,
                    radius: isHovered ? 12 : 3,
                    y: isHovered ? 6 : 1
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isHovered)

                if playlist.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                        .allowsHitTesting(false)
                }

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

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHovered ? YMTheme.accent : YMTheme.fg)
                    .lineLimit(1)

                if let desc = playlist.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                } else if let count = playlist.trackCount {
                    Text(formatTrackCount(count))
                        .font(.caption)
                        .foregroundStyle(YMTheme.fg40)
                }
            }
            .frame(width: cardSize, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { inside in
            if inside && TrackHoverManager.shared.isScrollSuppressed { return }
            if isHovered != inside { isHovered = inside }
        }
        .onDisappear {
            if isHovered { isHovered = false }
        }
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Слушать плейлист", action: onPlay)
            Button("Перемешать", action: onShuffle)
            Button("Запустить волну по плейлисту", action: onWave)
            Divider()
            Button("Изменить плейлист...", action: onEdit)
            Button("Удалить плейлист", role: .destructive, action: onDelete)
        }
    }
}
