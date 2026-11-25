import SwiftUI
import AppKit

/// Chart (Чарт) view showing the Top 100 most popular tracks in Yandex Music with positions, shifts, and rich actions.
public struct ChartView: View {
    @UIState private var chartItems: [YMChartItem] = []
    @UIState private var cachedChartEntries: [(item: YMChartItem, track: YMTrack)] = []
    @UIState private var cachedChartTracks: [YMTrack] = []
    @UIState private var isLoading = true
    @UIState private var errorMessage: String? = nil
    @UIState private var selectedTrackId: String? = nil
    @UIState private var lastClickedTrackId: String? = nil
    @UIState private var lastClickTimestamp: TimeInterval = 0
    @UIState private var isScrolled = false

    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var coordinator = NavigationCoordinator.shared
    @UIState private var windowState = WindowState.shared
    private let networkClient = YMNetworkClient.shared

    public init() {}

    private var chartTracks: [YMTrack] {
        if !cachedChartTracks.isEmpty {
            return cachedChartTracks
        }
        return chartItems.compactMap(\.track)
    }

    public var body: some View {
        let currentTrackId = audioEngine.currentTrack?.id
        let isEnginePlaying = audioEngine.isPlaying
        let isCompactWidth = windowState.isCompactWidth
        let isMiniWidth = windowState.isMiniWidth

        Group {
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
                    VStack(alignment: .leading, spacing: 0) {
                        // Top Header (adaptive for narrow 440pt windows)
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 16) {
                                chartTitleBlock
                                Spacer(minLength: 12)
                                if !chartTracks.isEmpty {
                                    chartPlayButton(height: 36)
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                chartTitleBlock
                                if !chartTracks.isEmpty {
                                    chartPlayButton(height: 32)
                                }
                            }
                        }
                        .padding(.horizontal, isMiniWidth ? 16 : 24)
                        .padding(.top, windowState.topChromeContentPadding)
                        .padding(.bottom, 16)

                        // Table Column Headers
                        HStack(spacing: isMiniWidth ? 8 : 12) {
                            Text("#")
                                .frame(width: isMiniWidth ? 40 : 48, alignment: .center)

                            Color.clear
                                .frame(width: 40)

                            Text("ТРЕК")
                                .frame(minWidth: isMiniWidth ? 100 : 180, alignment: .leading)

                            Spacer()

                            if !isCompactWidth {
                                Text("АЛЬБОМ")
                                    .frame(width: 180, alignment: .leading)
                            }

                            Color.clear
                                .frame(width: isMiniWidth ? 28 : 32)

                            Text("ВРЕМЯ")
                                .frame(width: isMiniWidth ? 42 : 50, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(YMTheme.fg40)
                        .padding(.horizontal, isMiniWidth ? 18 : 24)
                        .padding(.bottom, 8)

                        Divider()
                            .overlay(YMTheme.border)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 6)

                        LazyVStack(spacing: 2) {
                            ForEach(cachedChartEntries.indices, id: \.self) { index in
                                let entry = cachedChartEntries[index]
                                let isCurrent = currentTrackId == entry.track.id
                                let rowHoverId = "chart_\(index)_\(entry.track.id)"
                                ChartTrackRow(
                                    item: entry.item,
                                    track: entry.track,
                                    index: index,
                                    rowHoverId: rowHoverId,
                                    isCurrentTrack: isCurrent,
                                    isPlaying: isCurrent && isEnginePlaying,
                                    isSelected: selectedTrackId == entry.track.id,
                                    isCompactWidth: isCompactWidth,
                                    isMiniWidth: isMiniWidth,
                                    themeKey: YMTheme.themeRevisionKey,
                                    onPlay: {
                                        selectedTrackId = entry.track.id
                                        audioEngine.isWaveMode = false
                                        audioEngine.assignQueue(chartTracks, startingAt: index)
                                    },
                                    onTapRow: {
                                        handleRowTap(track: entry.track, index: index)
                                    },
                                    onArtistSelect: { artist in
                                        coordinator.navigate(to: .artist(id: artist.id, name: artist.name))
                                    },
                                    onAlbumSelect: { album in
                                        coordinator.navigate(to: .album(id: album.id, title: album.title))
                                    },
                                    onShowLyrics: {
                                        coordinator.showLyrics(for: entry.track)
                                    }
                                )
                                .equatable()
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 90)
                    }
                    .background(alignment: .top) {
                        if #unavailable(macOS 15.0) {
                            YMScrollTopSentinel(
                                coordinateSpaceName: "chart_scroll",
                                threshold: 64,
                                isScrolled: $isScrolled
                            )
                        }
                    }
                }
                .ymTrackScrollOffset(threshold: 64, isScrolled: $isScrolled)
                .coordinateSpace(name: "chart_scroll")
                .overlay(alignment: .top) {
                    YMStickyTopBar(title: "Чарт", isVisible: isScrolled)
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

    @ViewBuilder
    private var chartTitleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Чарт")
                .font(.system(size: windowState.isCompactWidth ? 24 : 28, weight: .bold))
                .foregroundStyle(YMTheme.fg)

            Text("Топ треков, которые прямо сейчас слушают в Яндекс Музыке")
                .font(.system(size: 13))
                .foregroundStyle(YMTheme.fg60)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func chartPlayButton(height: CGFloat) -> some View {
        Button {
            audioEngine.isWaveMode = false
            audioEngine.assignQueue(chartTracks, startingAt: 0)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                Text("Слушать чарт")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: height))
    }

    private func handleRowTap(track: YMTrack, index: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        let clickCount = NSApp?.currentEvent?.clickCount ?? 1
        let isDouble = clickCount >= 2
            || (selectedTrackId == track.id
                && lastClickedTrackId == track.id
                && (now - lastClickTimestamp) <= NSEvent.doubleClickInterval)
        selectedTrackId = track.id
        lastClickedTrackId = track.id
        lastClickTimestamp = now
        if isDouble {
            audioEngine.isWaveMode = false
            audioEngine.assignQueue(chartTracks, startingAt: index)
        }
    }

    private func loadChart() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let items = try await networkClient.fetchChart()
                let validEntries = items.compactMap { item -> (item: YMChartItem, track: YMTrack)? in
                    guard let track = item.track else { return nil }
                    return (item: item, track: track)
                }
                let tracks = validEntries.map(\.track)
                await MainActor.run {
                    self.chartItems = items
                    self.cachedChartEntries = validEntries
                    self.cachedChartTracks = tracks
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

private struct ChartPlayingCoverOverlay: View {
    let isPlaying: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.6))
                .frame(width: 40, height: 40)

            YMPlayingEqualizerView(color: YMTheme.accent, barWidth: 2.5, maxHeight: 15, isPlaying: isPlaying)
        }
        .frame(width: 40, height: 40)
    }
}

extension ChartPlayingCoverOverlay: @preconcurrency Equatable {
    static func == (lhs: ChartPlayingCoverOverlay, rhs: ChartPlayingCoverOverlay) -> Bool {
        lhs.isPlaying == rhs.isPlaying
    }
}

private struct ChartRowBackgroundOverlay: View {
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

private struct ChartRowCoverView: View {
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
                    ChartPlayingCoverOverlay(isPlaying: isPlaying)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Пауза" : "Воспроизвести трек")
    }
}

private struct ChartTrackRow: View {
    let item: YMChartItem
    let track: YMTrack
    let index: Int
    let rowHoverId: String
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let isSelected: Bool
    let isCompactWidth: Bool
    let isMiniWidth: Bool
    let themeKey: String
    let onPlay: () -> Void
    let onTapRow: () -> Void
    let onArtistSelect: (YMArtist) -> Void
    let onAlbumSelect: (YMAlbum) -> Void
    let onShowLyrics: () -> Void

    private let hoverManager = TrackHoverManager.shared

    private var position: Int {
        item.chart?.position ?? (index + 1)
    }

    private func triggerPlaybackAction() {
        if isCurrentTrack {
            AudioPlayerEngine.shared.togglePlayPause()
        } else {
            onPlay()
        }
    }

    var body: some View {
        HStack(spacing: isMiniWidth ? 8 : 12) {
            rankView
            coverAndPlayView
            titleAndArtistsView
            Spacer(minLength: 4)
            if !isCompactWidth {
                albumView
            }
            likeButtonView
            durationView
        }
        .padding(.vertical, 6)
        .padding(.horizontal, isMiniWidth ? 6 : 10)
        .background(
            ZStack(alignment: .leading) {
                ChartRowBackgroundOverlay(
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
            rowContextMenu
        }
    }

    @ViewBuilder
    private var rankView: some View {
        HStack(spacing: isMiniWidth ? 2 : 3) {
            if position <= 3 {
                Text("\(position)")
                    .font(.system(size: isMiniWidth ? 13 : 14, weight: .bold).monospacedDigit())
                    .foregroundColor(YMTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: isMiniWidth ? 24 : 28, alignment: .trailing)
            } else {
                Text("\(position)")
                    .font(.system(size: isMiniWidth ? 12 : 13, weight: isCurrentTrack ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isCurrentTrack ? YMTheme.accent : YMTheme.fg60)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: isMiniWidth ? 24 : 28, alignment: .trailing)
            }

            shiftIndicator
                .frame(width: isMiniWidth ? 12 : 14, alignment: .center)
        }
        .frame(width: isMiniWidth ? 40 : 48)
    }

    @ViewBuilder
    private var coverAndPlayView: some View {
        ChartRowCoverView(
            track: track,
            rowHoverId: rowHoverId,
            isCurrentTrack: isCurrentTrack,
            isPlaying: isPlaying,
            onPlayAction: triggerPlaybackAction
        )
    }

    @ViewBuilder
    private var titleAndArtistsView: some View {
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
    }

    @ViewBuilder
    private var albumView: some View {
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

    @ViewBuilder
    private var likeButtonView: some View {
        HStack(spacing: 4) {
            YMTrackOfflineBadge(trackId: track.id)
            YMLikeHeartButton(track: track, buttonWidth: isMiniWidth ? 28 : 32)
        }
    }

    @ViewBuilder
    private var durationView: some View {
        Text(track.formattedDuration)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(YMTheme.fg40)
            .frame(width: isMiniWidth ? 42 : 50, alignment: .trailing)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
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
        Button("Запустить Мою волну по треку") {
            AudioPlayerEngine.shared.startWave(forTrack: track)
        }
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
        OfflineDownloadContextMenuItem(track: track)
        LikeContextMenuItem(track: track)
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

extension ChartTrackRow: @preconcurrency Equatable {
    static func == (lhs: ChartTrackRow, rhs: ChartTrackRow) -> Bool {
        lhs.track.id == rhs.track.id &&
        lhs.index == rhs.index &&
        lhs.rowHoverId == rhs.rowHoverId &&
        lhs.isCurrentTrack == rhs.isCurrentTrack &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isCompactWidth == rhs.isCompactWidth &&
        lhs.isMiniWidth == rhs.isMiniWidth &&
        lhs.themeKey == rhs.themeKey
    }
}
