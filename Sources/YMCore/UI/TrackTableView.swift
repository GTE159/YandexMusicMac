import SwiftUI
import AppKit

/// Modern native macOS track list with smooth lazy rendering, column headers,
/// interactive hover & selection cards, instant play buttons, and seamless context menus.
public struct TrackTableView: View {
    public let tracks: [YMTrack]
    public let onPlayTrack: (YMTrack) -> Void
    public var onTrackAppear: ((YMTrack) -> Void)? = nil
    public var onLoadMore: (() -> Void)? = nil
    public var onRemoveFromPlaylist: ((YMTrack, Int) -> Void)? = nil
    public var showHeader: Bool = true
    public var showAlbum: Bool = true
    public var isSelectionMode: Bool = false
    public var externalSelectedIds: Binding<Set<String>>? = nil

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var internalSelectedIds: Set<String> = []
    @UIState private var selectionAnchorId: String? = nil
    @UIState private var lastClickedTrackId: String? = nil
    @UIState private var lastClickTimestamp: TimeInterval = 0

    public init(
        tracks: [YMTrack],
        onPlayTrack: @escaping (YMTrack) -> Void,
        onTrackAppear: ((YMTrack) -> Void)? = nil,
        onLoadMore: (() -> Void)? = nil,
        onRemoveFromPlaylist: ((YMTrack, Int) -> Void)? = nil,
        showHeader: Bool = true,
        showAlbum: Bool = true,
        isSelectionMode: Bool = false,
        externalSelectedIds: Binding<Set<String>>? = nil
    ) {
        self.tracks = tracks
        self.onPlayTrack = onPlayTrack
        self.onTrackAppear = onTrackAppear
        self.onLoadMore = onLoadMore
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.showHeader = showHeader
        self.showAlbum = showAlbum
        self.isSelectionMode = isSelectionMode
        self.externalSelectedIds = externalSelectedIds
    }

    private var activeSelectedIds: Set<String> {
        externalSelectedIds?.wrappedValue ?? internalSelectedIds
    }

    private func setActiveSelectedIds(_ ids: Set<String>) {
        if let external = externalSelectedIds {
            external.wrappedValue = ids
        } else {
            internalSelectedIds = ids
        }
    }

    public var body: some View {
        let currentTrackId = audioEngine.currentTrack?.id
        let isEnginePlaying = audioEngine.isPlaying
        let isCompactWidth = windowState.isCompactWidth
        let isMiniWidth = windowState.isMiniWidth

        VStack(spacing: 0) {
            if showHeader && !tracks.isEmpty {
                headerView(isCompactWidth: isCompactWidth, isMiniWidth: isMiniWidth)
                Divider()
                    .overlay(YMTheme.border)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }

            LazyVStack(spacing: 2) {
                ForEach(tracks.indices, id: \.self) { index in
                    let track = tracks[index]
                    if track.isSpacer {
                        Color.clear.frame(height: 16)
                    } else if track.isPlaceholder {
                        HStack(spacing: isMiniWidth ? 8 : 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(YMTheme.fg40.opacity(0.5))
                                .frame(width: isMiniWidth ? 30 : 38, alignment: .center)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(YMTheme.surfaceComponent)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(YMTheme.surfaceComponent)
                                    .frame(width: 120, height: 12)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(YMTheme.surfaceComponent.opacity(0.6))
                                    .frame(width: 80, height: 10)
                            }
                            .frame(minWidth: isMiniWidth ? 100 : 180, alignment: .leading)
                            Spacer(minLength: 4)
                            Color.clear.frame(width: isMiniWidth ? 42 : 50)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, isMiniWidth ? 6 : 10)
                        .onAppear {
                            onTrackAppear?(track)
                            if index >= tracks.count - 6 {
                                onLoadMore?()
                            }
                        }
                    } else {
                        let isCurrent = currentTrackId == track.id
                        let rowHoverId = "\(index)_\(track.id)"
                        let isSelected = activeSelectedIds.contains(track.id)
                        ModernTrackRow(
                            track: track,
                            index: index,
                            rowHoverId: rowHoverId,
                            isCurrentTrack: isCurrent,
                            isPlaying: isCurrent && isEnginePlaying,
                            isSelected: isSelected,
                            isSelectionMode: isSelectionMode,
                            showAlbum: showAlbum,
                            isCompactWidth: isCompactWidth,
                            isMiniWidth: isMiniWidth,
                            themeKey: YMTheme.themeRevisionKey,
                            onPlay: {
                                setActiveSelectedIds([track.id])
                                selectionAnchorId = track.id
                                onPlayTrack(track)
                            },
                            onTapRow: {
                                handleRowTap(track: track, index: index)
                            },
                            onArtistSelect: { artist in
                                coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                            },
                            onAlbumSelect: { album in
                                coordinator.navigate(to: .album(id: album.id, title: album.title))
                            },
                            onShowLyrics: {
                                coordinator.showLyrics(for: track)
                            },
                            onRemoveFromPlaylist: onRemoveFromPlaylist.map { handler in
                                { handler(track, index) }
                            },
                            contextTracksProvider: {
                                resolveContextTracks(for: track)
                            }
                        )
                        .equatable()
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
    }

    private func handleRowTap(track: YMTrack, index: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let modifiers = NSApp?.currentEvent?.modifierFlags ?? []
        let isCommandPressed = modifiers.contains(.command)
        let isShiftPressed = modifiers.contains(.shift)

        if isShiftPressed {
            let anchorIdx = selectionAnchorId.flatMap { anchorId in
                tracks.firstIndex(where: { $0.id == anchorId })
            } ?? index
            let low = min(anchorIdx, index)
            let high = max(anchorIdx, index)
            var updated = activeSelectedIds
            for i in low...high {
                let candidate = tracks[i]
                if !candidate.isSpacer {
                    updated.insert(candidate.id)
                }
            }
            setActiveSelectedIds(updated)
            lastClickedTrackId = track.id
            lastClickTimestamp = now
            return
        }

        if isCommandPressed || isSelectionMode {
            var updated = activeSelectedIds
            if updated.contains(track.id) {
                updated.remove(track.id)
            } else {
                updated.insert(track.id)
            }
            setActiveSelectedIds(updated)
            selectionAnchorId = track.id
            lastClickedTrackId = track.id
            lastClickTimestamp = now
            return
        }

        let clickCount = NSApp?.currentEvent?.clickCount ?? 1
        let isDouble = clickCount >= 2
            || (activeSelectedIds == [track.id]
                && lastClickedTrackId == track.id
                && (now - lastClickTimestamp) <= NSEvent.doubleClickInterval)
        setActiveSelectedIds([track.id])
        selectionAnchorId = track.id
        lastClickedTrackId = track.id
        lastClickTimestamp = now
        if isDouble {
            onPlayTrack(track)
        }
    }

    private func resolveContextTracks(for rightClickedTrack: YMTrack) -> [YMTrack] {
        let selected = activeSelectedIds
        guard selected.contains(rightClickedTrack.id), selected.count > 1 else {
            return [rightClickedTrack]
        }
        let ordered = tracks.filter { !$0.isSpacer && selected.contains($0.id) }
        return ordered.isEmpty ? [rightClickedTrack] : ordered
    }

    @ViewBuilder
    private func headerView(isCompactWidth: Bool, isMiniWidth: Bool) -> some View {
        HStack(spacing: isMiniWidth ? 8 : 12) {
            Text("#")
                .frame(width: isMiniWidth ? 28 : 36, alignment: .center)

            Color.clear
                .frame(width: 40, height: 1)

            Text("ТРЕК")
                .frame(minWidth: isMiniWidth ? 100 : 180, alignment: .leading)

            Spacer(minLength: 4)

            if showAlbum && !isCompactWidth {
                Text("АЛЬБОМ")
                    .frame(width: 180, alignment: .leading)
            }

            Color.clear
                .frame(width: isMiniWidth ? 28 : 32, height: 1)

            Text("ВРЕМЯ")
                .frame(width: isMiniWidth ? 42 : 50, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(YMTheme.fg40)
        .padding(.horizontal, isMiniWidth ? 6 : 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Modern Track Row

/// Isolated leaf view for currently playing track cover overlay.
/// Bypasses CPU layout/drawing invalidations of parent rows and ScrollView.
private struct TrackPlayingCoverOverlay: View {
    let isPlaying: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.55))
                .frame(width: 40, height: 40)

            YMPlayingEqualizerView(color: YMTheme.accent, barWidth: 2.5, maxHeight: 15, isPlaying: isPlaying)
        }
        .frame(width: 40, height: 40)
    }
}

extension TrackPlayingCoverOverlay: @preconcurrency Equatable {
    static func == (lhs: TrackPlayingCoverOverlay, rhs: TrackPlayingCoverOverlay) -> Bool {
        lhs.isPlaying == rhs.isPlaying
    }
}

private struct TrackRowBackgroundOverlay: View {
    let rowHoverId: String
    let isSelected: Bool
    let isCurrentTrack: Bool

    var body: some View {
        let isHovered = TrackHoverManager.shared.state(for: rowHoverId).isHovered
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? YMTheme.surfaceComponentHover
                        : (isCurrentTrack
                            ? YMTheme.accent.opacity(YMTheme.isLight ? 0.12 : 0.09)
                            : (isHovered ? YMTheme.surfaceComponent : Color.clear))
                )

            if isCurrentTrack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(YMTheme.accent.opacity(0.24), lineWidth: 1)
            }
        }
    }
}

private struct TrackRowCoverView: View {
    let track: YMTrack
    let rowHoverId: String
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let onPlayAction: () -> Void

    var body: some View {
        let isHovered = TrackHoverManager.shared.state(for: rowHoverId).isHovered
        Button {
            onPlayAction()
        } label: {
            ZStack {
                CachedCoverImage(
                    coverUri: track.effectiveCoverUri,
                    size: .small,
                    displaySize: 40,
                    cornerRadius: 6
                )

                if isHovered {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 40, height: 40)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(isCurrentTrack ? YMTheme.accent : Color.white)
                        .font(.system(size: isCurrentTrack ? 14 : 13, weight: isCurrentTrack ? .bold : .regular))
                } else if isCurrentTrack {
                    TrackPlayingCoverOverlay(isPlaying: isPlaying)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Пауза" : "Воспроизвести трек")
    }
}

private struct ModernTrackRow: View {
    let track: YMTrack
    let index: Int
    let rowHoverId: String
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isSelected: Bool
    let isSelectionMode: Bool
    let showAlbum: Bool
    let isCompactWidth: Bool
    let isMiniWidth: Bool
    let themeKey: String
    let onPlay: () -> Void
    let onTapRow: () -> Void
    let onArtistSelect: (YMArtist) -> Void
    let onAlbumSelect: (YMAlbum) -> Void
    let onShowLyrics: () -> Void
    let onRemoveFromPlaylist: (() -> Void)?
    let contextTracksProvider: () -> [YMTrack]

    private let hoverManager = TrackHoverManager.shared

    private func triggerPlaybackAction() {
        if isCurrentTrack {
            AudioPlayerEngine.shared.togglePlayPause()
        } else {
            onPlay()
        }
    }

    var body: some View {
        HStack(spacing: isMiniWidth ? 8 : 12) {
            // Track Number or Multi-Select Checkbox (fixed width to prevent layout jitter)
            Group {
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? YMTheme.accent : YMTheme.fg40)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: isCurrentTrack ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(isCurrentTrack ? YMTheme.accent : YMTheme.fg40)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(width: isMiniWidth ? 30 : 38, alignment: .center)

            // Cover thumbnail with isolated hover/play overlay
            TrackRowCoverView(
                track: track,
                rowHoverId: rowHoverId,
                isCurrentTrack: isCurrentTrack,
                isPlaying: isPlaying,
                onPlayAction: triggerPlaybackAction
            )

            // Title & Artists
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: 13, weight: isCurrentTrack ? .bold : .medium))
                    .foregroundStyle(isCurrentTrack ? YMTheme.accent : YMTheme.fg)
                    .lineLimit(1)

                if !track.artists.isEmpty {
                    let artistsToDisplay = Array(track.artists.prefix(4))
                    HStack(spacing: 4) {
                        ForEach(artistsToDisplay) { artist in
                            YMHoverLinkText(
                                text: artist.name,
                                font: .system(size: 12),
                                baseColor: YMTheme.fg60,
                                hoverColor: YMTheme.fg
                            ) {
                                onArtistSelect(artist)
                            }

                            if artist.id != artistsToDisplay.last?.id {
                                Text("•")
                                    .font(.system(size: 8))
                                    .foregroundStyle(YMTheme.fg40)
                            }
                        }
                    }
                    .clipped()
                } else {
                    Text(track.artistsString)
                        .font(.system(size: 12))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: isMiniWidth ? 100 : 180, alignment: .leading)

            Spacer(minLength: 4)

            // Album
            if showAlbum && !isCompactWidth {
                if let album = track.albums.first {
                    YMHoverLinkText(
                        text: album.title,
                        font: .system(size: 12),
                        baseColor: YMTheme.fg60,
                        hoverColor: YMTheme.fg
                    ) {
                        onAlbumSelect(album)
                    }
                    .frame(width: 180, alignment: .leading)
                } else {
                    Color.clear
                        .frame(width: 180)
                }
            }

            // Offline Badge + Like Heart Button (both isolated subviews)
            HStack(spacing: 4) {
                YMTrackOfflineBadge(trackId: track.id)
                YMLikeHeartButton(track: track, buttonWidth: isMiniWidth ? 28 : 32)
            }

            // Duration
            Text(track.formattedDuration)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(YMTheme.fg40)
                .frame(width: isMiniWidth ? 42 : 50, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, isMiniWidth ? 6 : 10)
        .background(
            ZStack(alignment: .leading) {
                TrackRowBackgroundOverlay(
                    rowHoverId: rowHoverId,
                    isSelected: isSelected,
                    isCurrentTrack: isCurrentTrack
                )
                TrackHoverAnchor(trackId: rowHoverId)
            }
        )
        .contentShape(Rectangle())
        .onAppear {
            hoverManager.rowDidAppear(trackId: rowHoverId)
        }
        .onDisappear {
            hoverManager.rowDidDisappear(trackId: rowHoverId)
        }
        .onTapGesture {
            onTapRow()
        }
        .contextMenu {
            let selectedTracks = contextTracksProvider()
            if selectedTracks.count > 1 {
                TrackContextMultiSelectWaveMenu(selectedTracks: selectedTracks)
                Button("Добавить выбранные (\(selectedTracks.count)) в конец очереди") {
                    Task {
                        let resolved = await LikesService.shared.resolveTracks(selectedTracks)
                        if !resolved.isEmpty {
                            AudioPlayerEngine.shared.addToQueue(resolved)
                        }
                    }
                }
                Button("Скачать выбранные (\(selectedTracks.count)) для оффлайна") {
                    Task {
                        let resolved = await LikesService.shared.resolveTracks(selectedTracks)
                        if !resolved.isEmpty {
                            OfflineDownloadManager.shared.enqueueDownloads(tracks: resolved)
                        }
                    }
                }
                Divider()
            } else {
                Button("Воспроизвести сейчас") {
                    onPlay()
                }
                Button("Воспроизвести следующим") {
                    AudioPlayerEngine.shared.insertNext(track)
                }
                Button("Добавить в конец очереди") {
                    AudioPlayerEngine.shared.addToQueue([track])
                }
                Divider()
                TrackContextSingleWaveMenu(track: track)
                ForEach(track.artists) { artist in
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
                    onShowLyrics()
                }
                Divider()
                AddToPlaylistContextMenu(track: track)
                if let onRemoveFromPlaylist = onRemoveFromPlaylist {
                    Button("Удалить из плейлиста", role: .destructive) {
                        onRemoveFromPlaylist()
                    }
                }
                OfflineDownloadContextMenuItem(track: track)
                LikeContextMenuItem(track: track)
            }
        }
    }
}

private struct TrackContextSingleWaveMenu: View {
    let track: YMTrack
    @UIState private var audioEngine = AudioPlayerEngine.shared

    var body: some View {
        if audioEngine.isWaveMode {
            Button("Добавить в текущую волну") {
                Task {
                    await WaveSessionController.shared.addTracksToActiveWave([track])
                }
            }
        }
        Button("Запустить Мою волну по треку") {
            audioEngine.startWave(forTrack: track)
        }
    }
}

private struct TrackContextMultiSelectWaveMenu: View {
    let selectedTracks: [YMTrack]
    @UIState private var audioEngine = AudioPlayerEngine.shared

    var body: some View {
        if audioEngine.isWaveMode {
            Button("Добавить выбранные (\(selectedTracks.count)) в текущую волну") {
                Task {
                    await WaveSessionController.shared.addTracksToActiveWave(selectedTracks)
                }
            }
        } else {
            Button("Запустить Мою волну с выбранными (\(selectedTracks.count))") {
                Task {
                    await WaveSessionController.shared.startWaveWithTracksAsLiked(selectedTracks)
                }
            }
        }
    }
}

extension ModernTrackRow: @preconcurrency Equatable {
    static func == (lhs: ModernTrackRow, rhs: ModernTrackRow) -> Bool {
        lhs.track.id == rhs.track.id &&
        lhs.track.isPlaceholder == rhs.track.isPlaceholder &&
        lhs.track.displayTitle == rhs.track.displayTitle &&
        lhs.index == rhs.index &&
        lhs.rowHoverId == rhs.rowHoverId &&
        lhs.isCurrentTrack == rhs.isCurrentTrack &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isSelectionMode == rhs.isSelectionMode &&
        lhs.showAlbum == rhs.showAlbum &&
        lhs.isCompactWidth == rhs.isCompactWidth &&
        lhs.isMiniWidth == rhs.isMiniWidth &&
        lhs.themeKey == rhs.themeKey
    }
}
