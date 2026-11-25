import SwiftUI

/// Modern, beautiful "Мне нравится" (Favorites) view featuring iconic gradient hero banner,
/// quick play/shuffle/wave actions, glass search filter, and seamless scrolling track list.
public struct FavoritesListView: View {
    @UIState private var likesService = LikesService.shared
    @UIState private var audioEngine = AudioPlayerEngine.shared
    @UIState private var windowState = WindowState.shared
    @UIState private var coordinator = NavigationCoordinator.shared

    @UIState private var filterQuery = ""
    @UIState private var filterTask: Task<Void, Never>? = nil
    @UIState private var isScrolled = false

    @UIState private var cachedDisplayedTracks: [YMTrack] = []
    @UIState private var cachedTotalDuration: String = ""
    @UIState private var isMultiSelectMode: Bool = false
    @UIState private var selectedTrackIds: Set<String> = []
    @UIState private var isApplyingSelectionAction: Bool = false

    public init() {}

    private var isFiltered: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedTracks: [YMTrack] {
        if isFiltered {
            return cachedDisplayedTracks
        } else {
            return likesService.likedTracks
        }
    }

    private var totalDurationFormatted: String {
        cachedTotalDuration
    }

    private func formatTrackCount(_ count: Int) -> String {
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

    private func recalculateDisplayedTracks() {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            cachedDisplayedTracks = []
        } else {
            cachedDisplayedTracks = likesService.searchInLikes(query: q)
        }

        let tracks = displayedTracks
        let totalMs = tracks.compactMap(\.durationMs).reduce(0, +)
        if totalMs > 0 {
            let totalSeconds = totalMs / 1000
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            if hours > 0 {
                cachedTotalDuration = "\(hours) ч \(minutes) мин"
            } else {
                cachedTotalDuration = "\(minutes) мин"
            }
        } else {
            cachedTotalDuration = ""
        }
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 20) {
                // Hero Header
                let tileSize: CGFloat = windowState.isMiniWidth ? 80 : (windowState.isCompactWidth ? 96 : 120)
                let iconSize: CGFloat = windowState.isMiniWidth ? 34 : (windowState.isCompactWidth ? 42 : 50)
                HStack(alignment: .bottom, spacing: windowState.isCompactWidth ? 16 : 20) {
                    // Iconic Gradient Heart Tile
                    ZStack {
                        RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 228 / 255, green: 92 / 255, blue: 78 / 255),   // Deep coral
                                        Color(red: 196 / 255, green: 52 / 255, blue: 102 / 255),  // Rich crimson
                                        Color(red: 108 / 255, green: 44 / 255, blue: 132 / 255)   // Modern plum
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: tileSize, height: tileSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                Color.white.opacity(0.24),
                                                Color.white.opacity(0.0)
                                            ],
                                            center: .topLeading,
                                            startRadius: 4,
                                            endRadius: tileSize * 0.8
                                        )
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: windowState.isMiniWidth ? 12 : 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: Color(red: 196 / 255, green: 52 / 255, blue: 102 / 255).opacity(0.28), radius: 18, y: 8)

                        Image(systemName: "heart.fill")
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.24), radius: 6, y: 3)
                    }

                    // Metadata & Actions
                    VStack(alignment: .leading, spacing: windowState.isCompactWidth ? 6 : 8) {
                        Text("ПЛЕЙЛИСТ")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(YMTheme.fg40)
                            .tracking(1.2)

                        Text("Мне нравится")
                            .font(.system(size: windowState.isCompactWidth ? 22 : 28, weight: .bold))
                            .foregroundStyle(YMTheme.fg)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(formatTrackCount(likesService.likedTrackIds.count))
                            if !totalDurationFormatted.isEmpty {
                                Text("• \(totalDurationFormatted)")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(YMTheme.fg60)
                        .lineLimit(1)

                        // Adaptive Actions Bar
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                playAllButton(title: "Слушать всё", height: 32)
                                shuffleButton(title: "Перемешать", height: 32)
                                waveButton(title: "Волна по любимому", height: 32)
                                FavoritesDownloadButton(
                                    filterQuery: filterQuery,
                                    displayedTracks: displayedTracks,
                                    height: 32,
                                    compact: false
                                )
                                selectModeToggleButton(title: isMultiSelectMode ? "Готово" : "Выбрать", height: 32)
                            }

                            HStack(spacing: 8) {
                                playAllButton(title: "Слушать", height: 30)
                                shuffleButton(title: "Микс", height: 30)
                                waveButton(title: "Волна", height: 30)
                                FavoritesDownloadButton(
                                    filterQuery: filterQuery,
                                    displayedTracks: displayedTracks,
                                    height: 30,
                                    compact: true
                                )
                                selectModeToggleButton(title: isMultiSelectMode ? "Готово" : "Выбрать", height: 30)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    playAllButton(title: "Слушать", height: 30)
                                    shuffleButton(title: "Микс", height: 30)
                                    FavoritesDownloadButton(
                                        filterQuery: filterQuery,
                                        displayedTracks: displayedTracks,
                                        height: 30,
                                        compact: true
                                    )
                                }
                                HStack(spacing: 8) {
                                    waveButton(title: "Волна по любимому", height: 30)
                                    selectModeToggleButton(title: isMultiSelectMode ? "Готово" : "Выбрать", height: 30)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, windowState.isMiniWidth ? 16 : 24)
                .padding(.top, windowState.topChromeContentPadding)

                // Search & Filter Input Bar
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(YMTheme.fg40)

                    TextField("Поиск по моим трекам, исполнителям и альбомам...", text: $filterQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if likesService.isIndexingCatalog {
                        ProgressView()
                            .controlSize(.small)
                            .help("Индексация треков для поиска...")
                    }

                    if !filterQuery.isEmpty {
                        Text("\(displayedTracks.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(YMTheme.fg40)

                        Button {
                            filterQuery = ""
                            likesService.pruneSearchCatalogIfNeeded()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(YMTheme.fg40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(YMTheme.surfaceComponent)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(YMTheme.border, lineWidth: 1))
                )
                .padding(.horizontal, 24)

                // Tracklist Content
                if likesService.isSyncing && displayedTracks.isEmpty {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Синхронизация ваших треков...")
                            .font(.caption)
                            .foregroundStyle(YMTheme.fg40)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if likesService.likedTrackIds.isEmpty && displayedTracks.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "heart")
                            .font(.system(size: 44))
                            .foregroundStyle(YMTheme.fg40)
                        Text("Здесь будут ваши любимые треки")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                        Text("Нажимайте на сердечко у любых треков, чтобы собрать свою коллекцию")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if displayedTracks.isEmpty && !filterQuery.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundStyle(YMTheme.fg40)
                        Text("В Избранном ничего не найдено")
                            .font(.headline)
                            .foregroundStyle(YMTheme.fg)
                        Text("По запросу «\(filterQuery)» треков не найдено")
                            .font(.subheadline)
                            .foregroundStyle(YMTheme.fg60)
                        Button("Очистить поиск") {
                            filterQuery = ""
                            likesService.pruneSearchCatalogIfNeeded()
                        }
                        .buttonStyle(YMGlassPillButtonStyle(primary: false))
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    if isMultiSelectMode || selectedTrackIds.count > 1 {
                        selectionActionBar
                            .padding(.horizontal, 24)
                    }

                    TrackTableView(
                        tracks: displayedTracks,
                        onPlayTrack: { track in
                            audioEngine.isWaveMode = false
                            let isFiltered = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            let playable = displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }
                            if let idx = playable.firstIndex(where: { $0.id == track.id }) {
                                audioEngine.setQueue(playable, startingAt: idx)
                                if !isFiltered {
                                    attachSequentialLikesContinuation()
                                }
                            } else {
                                Task {
                                    if let resolved = await likesService.fetchTrackImmediately(trackId: track.id) {
                                        let updatedPlayable = displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }
                                        if let newIdx = updatedPlayable.firstIndex(where: { $0.id == resolved.id }) {
                                            audioEngine.setQueue(updatedPlayable, startingAt: newIdx)
                                        } else {
                                            audioEngine.setQueue([resolved], startingAt: 0)
                                        }
                                        if !isFiltered {
                                            attachSequentialLikesContinuation()
                                        }
                                    }
                                }
                            }
                        },
                        onTrackAppear: { track in
                            if track.isPlaceholder {
                                likesService.loadBatchIfNeeded(forTrackId: track.id)
                            }
                        },
                        onLoadMore: {
                            Task {
                                await likesService.loadMoreLikedTracks()
                            }
                        },
                        isSelectionMode: isMultiSelectMode,
                        externalSelectedIds: $selectedTrackIds
                    )
                    .padding(.horizontal, 14)

                    if likesService.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.8)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.bottom, 80)
            .background(alignment: .top) {
                if #unavailable(macOS 15.0) {
                    YMScrollTopSentinel(
                        coordinateSpaceName: "favorites_scroll",
                        threshold: 88,
                        isScrolled: $isScrolled
                    )
                }
            }
        }
        .ymTrackScrollOffset(threshold: 88, isScrolled: $isScrolled)
        .coordinateSpace(name: "favorites_scroll")
        .overlay(alignment: .top) {
            YMStickyTopBar(title: "Мне нравится", isVisible: isScrolled)
        }
        .ymScreenBackground()
        .onAppear {
            recalculateDisplayedTracks()
        }
        .onDisappear {
            filterTask?.cancel()
            filterTask = nil
        }
        .onChange(of: filterQuery) { _, newQuery in
            filterTask?.cancel()
            let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                recalculateDisplayedTracks()
            } else {
                filterTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    recalculateDisplayedTracks()
                }
            }
        }
        .onChange(of: likesService.likedTracks.count) { _, _ in
            recalculateDisplayedTracks()
        }
        .onChange(of: likesService.likedTrackIds.count) { _, _ in
            recalculateDisplayedTracks()
        }
        .onChange(of: likesService.isIndexingCatalog) { _, _ in
            recalculateDisplayedTracks()
        }
        .task {
            await likesService.ensureInitialLikesLoaded()
            recalculateDisplayedTracks()
        }
        .task(id: filterQuery) {
            let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await likesService.ensureAllLikedTracksLoadedForSearch()
            recalculateDisplayedTracks()
        }
    }

    @ViewBuilder
    private func playAllButton(title: String, height: CGFloat) -> some View {
        Button {
            let isFiltered = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let playable = displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }
            if !playable.isEmpty {
                audioEngine.isWaveMode = false
                audioEngine.setQueue(playable, startingAt: 0)
                if !isFiltered {
                    attachSequentialLikesContinuation()
                }
            }
        } label: {
            Label(title, systemImage: "play.fill")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: height))
        .disabled(displayedTracks.isEmpty)
    }

    @ViewBuilder
    private func shuffleButton(title: String, height: CGFloat) -> some View {
        Button {
            if !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                audioEngine.playShuffled(displayedTracks)
            } else {
                Task {
                    let randomTracks = await likesService.fetchRandomLikedTracksForShuffle(limit: 50)
                    audioEngine.playShuffled(randomTracks)
                    attachShuffledLikesContinuation()
                }
            }
        } label: {
            Label(title, systemImage: "shuffle")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(likesService.likedTrackIds.isEmpty && displayedTracks.isEmpty)
    }

    private func attachSequentialLikesContinuation() {
        let likes = likesService
        audioEngine.attachQueueContinuation { existingIds in
            await likes.loadNextLikedTracksForPlayback(excludingIds: existingIds, batchSize: 50)
        }
    }

    private func attachShuffledLikesContinuation() {
        let likes = likesService
        audioEngine.attachQueueContinuation { existingIds in
            await likes.fetchMoreRandomLikedTracksForShuffle(excludingIds: existingIds, limit: 50)
        }
    }

    @ViewBuilder
    private func waveButton(title: String, height: CGFloat) -> some View {
        Button {
            let playable = displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }
            audioEngine.startWave(forPlaylist: YMPlaylist(uid: "user", kind: 3, title: "Мне нравится"), tracks: Array(playable))
        } label: {
            Label(title, systemImage: "waveform.path.ecg")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(displayedTracks.isEmpty)
    }

    @ViewBuilder
    private func selectModeToggleButton(title: String, height: CGFloat) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isMultiSelectMode.toggle()
                if !isMultiSelectMode {
                    selectedTrackIds.removeAll()
                }
            }
        } label: {
            Label(title, systemImage: isMultiSelectMode ? "checkmark.circle.fill" : "checklist")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(displayedTracks.isEmpty)
        .help(isMultiSelectMode ? "Завершить выбор треков" : "Выбрать несколько треков для добавления в волну или скачивания")
    }

    private var selectedTracksInOrder: [YMTrack] {
        guard !selectedTrackIds.isEmpty else { return [] }
        return displayedTracks.filter { !$0.isSpacer && selectedTrackIds.contains($0.id) }
    }

    @ViewBuilder
    private var selectionActionBar: some View {
        let count = selectedTracksInOrder.count
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                selectionSummaryText(count: count)
                Spacer(minLength: 8)
                selectionActionButtons(count: count)
            }

            VStack(alignment: .leading, spacing: 8) {
                selectionSummaryText(count: count)
                HStack(spacing: 8) {
                    selectionActionButtons(count: count)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(YMTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(YMTheme.accent.opacity(0.32), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func selectionSummaryText(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(YMTheme.accent)
            Text(count > 0 ? "Выбрано: \(formatTrackCount(count))" : "Выберите треки галочками или ⌘/⇧ + кликом")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(YMTheme.fg)
        }
    }

    @ViewBuilder
    private func selectionActionButtons(count: Int) -> some View {
        let targets = selectedTracksInOrder
        Button {
            guard !targets.isEmpty, !isApplyingSelectionAction else { return }
            isApplyingSelectionAction = true
            Task {
                defer { isApplyingSelectionAction = false }
                if audioEngine.isWaveMode {
                    await WaveSessionController.shared.addTracksToActiveWave(targets)
                } else {
                    await WaveSessionController.shared.startWaveWithTracksAsLiked(targets)
                }
                selectedTrackIds.removeAll()
                isMultiSelectMode = false
            }
        } label: {
            Label(
                audioEngine.isWaveMode ? "Добавить в текущую волну" : "Волна по выбранным",
                systemImage: "waveform.path.ecg"
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: true, height: 28))
        .disabled(count == 0 || isApplyingSelectionAction)

        Button {
            guard !targets.isEmpty, !isApplyingSelectionAction else { return }
            isApplyingSelectionAction = true
            Task {
                defer { isApplyingSelectionAction = false }
                let resolved = await likesService.resolveTracks(targets)
                if !resolved.isEmpty {
                    OfflineDownloadManager.shared.enqueueDownloads(tracks: resolved)
                }
                selectedTrackIds.removeAll()
                isMultiSelectMode = false
            }
        } label: {
            Label("Скачать", systemImage: "arrow.down.circle")
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
        .disabled(count == 0 || isApplyingSelectionAction)

        if !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Выбрать все") {
                selectedTrackIds = Set(displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }.map(\.id))
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
        }

        if count > 0 {
            Button("Снять выбор") {
                selectedTrackIds.removeAll()
            }
            .buttonStyle(YMGlassPillButtonStyle(primary: false, height: 28))
        }
    }
}

// MARK: - Isolated Favorites Download Button

/// Isolates `OfflineDownloadManager` observation from `FavoritesListView` and hydrates lazy likes
/// before enqueuing downloads when the unfiltered Favorites library still contains placeholders.
private struct FavoritesDownloadButton: View {
    let filterQuery: String
    let displayedTracks: [YMTrack]
    let height: CGFloat
    let compact: Bool

    @UIState private var likesService = LikesService.shared
    @UIState private var offlineManager = OfflineDownloadManager.shared
    @UIState private var isPreparingBatch = false

    private var isFiltered: Bool {
        !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var targetCleanIds: [String] {
        if isFiltered {
            return displayedTracks.compactMap { track -> String? in
                guard !track.isPlaceholder && !track.isSpacer else { return nil }
                return OfflineTrackID.clean(track.id)
            }
        }
        if !likesService.likedTrackIds.isEmpty {
            return Array(likesService.likedTrackIds)
        }
        return displayedTracks.compactMap { track -> String? in
            guard !track.isSpacer else { return nil }
            return OfflineTrackID.clean(track.id)
        }
    }

    var body: some View {
        let ids = targetCleanIds
        let totalCount = ids.count
        let downloadedSet = offlineManager.downloadedTrackIds
        let downloadedCount = ids.reduce(0) { count, cleanId in
            count + (downloadedSet.contains(cleanId) ? 1 : 0)
        }
        let allDownloaded = totalCount > 0 && downloadedCount == totalCount

        // Fast O(1) guard avoids scanning all liked track IDs when no downloads are active
        let hasAnyEngineActivity = offlineManager.activeDownloadsCount > 0 || offlineManager.pendingDownloadsCount > 0
        let activeIds: [String] = hasAnyEngineActivity
            ? ids.filter { offlineManager.state(for: $0).phase.isActive }
            : []
        let isDownloadingAny = !activeIds.isEmpty

        Button {
            if isPreparingBatch || allDownloaded {
                return
            } else if isDownloadingAny {
                for id in activeIds {
                    offlineManager.cancelDownload(trackId: id)
                }
            } else if isFiltered {
                let playable = displayedTracks.filter { !$0.isPlaceholder && !$0.isSpacer && $0.available != false }
                offlineManager.enqueueDownloads(tracks: playable)
            } else {
                isPreparingBatch = true
                Task {
                    defer { isPreparingBatch = false }
                    let allPlayable = await likesService.resolveAllLikedTracksForBatchAction()
                    if !allPlayable.isEmpty {
                        offlineManager.enqueueDownloads(tracks: allPlayable)
                    }
                }
            }
        } label: {
            if isPreparingBatch {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.78)
                    Text(compact ? "..." : "Подготовка...")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else if allDownloaded {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(YMTheme.accent)
                    Text(compact ? "Оффлайн" : "Скачано")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else if isDownloadingAny {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.78)
                    Text(compact ? "\(downloadedCount)/\(totalCount)" : "Скачивание (\(downloadedCount)/\(totalCount))")
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                Label("Скачать", systemImage: "arrow.down.circle")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(YMGlassPillButtonStyle(primary: false, height: height))
        .disabled(totalCount == 0 || allDownloaded || isPreparingBatch)
        .help(
            allDownloaded
                ? "Все выбранные треки скачаны для оффлайн-прослушивания"
                : (isDownloadingAny ? "Нажмите для отмены скачивания" : "Скачать треки из Избранного для прослушивания без интернета")
        )
    }
}
