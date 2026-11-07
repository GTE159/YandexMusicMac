import Foundation
import Observation

// MARK: - Likes Response Models

public struct YMLikesLibraryResponse: Codable, Sendable {
    public let library: YMLibraryData?
    public let tracks: [YMLikedTrackItem]?

    public var allLikedItems: [YMLikedTrackItem] {
        if let libTracks = library?.tracks {
            return libTracks
        }
        if let directTracks = tracks {
            return directTracks
        }
        return []
    }

    public var allTrackIds: [String] {
        allLikedItems.map(\.id)
    }
}

public struct YMLibraryData: Codable, Sendable {
    public let tracks: [YMLikedTrackItem]?
}

public struct YMLikedTrackItem: Codable, Sendable {
    public let id: String
    public let albumId: String?

    public var trackIdentifier: String {
        if let albumId = albumId, !albumId.isEmpty {
            return "\(id):\(albumId)"
        }
        return id
    }

    enum CodingKeys: String, CodingKey {
        case id
        case albumId
        case track
    }

    public init(id: String, albumId: String? = nil) {
        self.id = id
        self.albumId = albumId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idString = FlexibleIDDecoder.decodeStringIfPresent(from: container, forKey: .id) {
            self.id = idString
            self.albumId = FlexibleIDDecoder.decodeStringIfPresent(from: container, forKey: .albumId)
        } else if let trackContainer = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .track),
                  let idString = FlexibleIDDecoder.decodeStringIfPresent(from: trackContainer, forKey: .id) {
            self.id = idString
            self.albumId = FlexibleIDDecoder.decodeStringIfPresent(from: trackContainer, forKey: .albumId)
        } else {
            self.id = UUID().uuidString
            self.albumId = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(albumId, forKey: .albumId)
    }
}

// MARK: - Likes Service

/// MainActor-isolated service providing O(1) liked state checks, placeholder virtualization and scroll-driven batch loading.
@Observable
@MainActor
public final class LikesService {
    public static let shared = LikesService()

    public private(set) var likedTrackIds: Set<String> = []

    /// Table-visible tracks. Contains all items as placeholders initially,
    /// and populates full YMTrack details as user scrolls.
    public private(set) var likedTracks: [YMTrack] = []

    /// Internal search buffer for personal library queries.
    @ObservationIgnored
    private var searchCatalog: [YMTrack] = []

    public private(set) var hasMoreLikes: Bool = false
    public private(set) var isLoadingMore: Bool = false
    public private(set) var isSyncing: Bool = false
    public private(set) var isIndexingCatalog: Bool = false
    public private(set) var hasLoadedInitialBatch: Bool = false

    private var allLikedItems: [YMLikedTrackItem] = []
    private var inFlightBatches: Set<Int> = []
    private var backgroundCatalogTask: Task<Void, Never>?
    private let networkClient: YMNetworkClient
    private let keychain: KeychainManager

    public init(
        networkClient: YMNetworkClient = .shared,
        keychain: KeychainManager = .shared
    ) {
        self.networkClient = networkClient
        self.keychain = keychain
    }

    @inline(__always)
    private func extractCleanId(from trackId: String) -> String {
        if let colonIndex = trackId.firstIndex(of: ":") {
            return String(trackId[..<colonIndex])
        }
        return trackId
    }

    /// O(1) check if track is in user's liked collection without array allocation
    public func isLiked(trackId: String) -> Bool {
        if likedTrackIds.contains(trackId) { return true }
        let cleanId = extractCleanId(from: trackId)
        return likedTrackIds.contains(cleanId)
    }

    /// Synchronizes liked track IDs with Yandex Music API
    public func syncLikes(uid: String? = nil) async throws {
        guard let resolvedUid = uid ?? AuthService.shared.currentUser?.userId ?? keychain.getUserId() else {
            print("[LikesService] No userId available to sync likes.")
            return
        }

        self.isSyncing = true
        defer { self.isSyncing = false }

        let response: YMLikesLibraryResponse = try await networkClient.request(
            endpoint: "/users/\(YMNetworkClient.escapePath(resolvedUid))/likes/tracks",
            cachePolicy: .reloadIgnoringLocalCacheData
        )

        self.allLikedItems = response.allLikedItems
        self.likedTrackIds = Set(allLikedItems.map(\.id))
        self.hasMoreLikes = self.likedTracks.count < self.allLikedItems.count || self.likedTracks.contains(where: \.isPlaceholder)
    }

    /// Ensures user's liked collection is loaded on demand without requiring manual refresh.
    public func ensureInitialLikesLoaded() async {
        guard !isSyncing, (!hasLoadedInitialBatch || likedTracks.isEmpty) else { return }
        do {
            _ = try await fetchLikedTracks(initialLimit: 50)
        } catch {
            print("[LikesService] Failed to load initial likes: \(error)")
        }
    }

    /// Synchronizes liked items and immediately hydrates the first batch (up to 50 real tracks).
    public func fetchLikedTracks(initialLimit: Int = 50) async throws -> [YMTrack] {
        guard let resolvedUid = AuthService.shared.currentUser?.userId ?? keychain.getUserId() else {
            print("[LikesService] No userId available to fetch liked tracks.")
            return []
        }

        self.isSyncing = true
        defer { self.isSyncing = false }

        let response: YMLikesLibraryResponse = try await networkClient.request(
            endpoint: "/users/\(YMNetworkClient.escapePath(resolvedUid))/likes/tracks",
            cachePolicy: .reloadIgnoringLocalCacheData
        )

        self.allLikedItems = response.allLikedItems
        self.likedTrackIds = Set(allLikedItems.map(\.id))
        self.searchCatalog = []
        self.inFlightBatches.removeAll()

        guard !allLikedItems.isEmpty else {
            self.likedTracks = []
            self.hasMoreLikes = false
            self.hasLoadedInitialBatch = true
            return []
        }

        // Preserve any freshly liked local tracks that haven't propagated to API yet
        let localUnsynced = self.likedTracks.filter { track in
            !track.isPlaceholder && !allLikedItems.contains(where: { $0.id == extractCleanId(from: track.id) })
        }

        let initialBatchSize = min(initialLimit, allLikedItems.count)
        let initialSlice = Array(allLikedItems.prefix(initialBatchSize))
        let idsToFetch = initialSlice.map(\.id)

        let fullTracks = try await networkClient.fetchTracks(trackIds: idsToFetch)
        var result = localUnsynced
        result.append(contentsOf: fullTracks)
        self.likedTracks = result
        self.searchCatalog = fullTracks
        self.hasMoreLikes = self.likedTracks.count < self.allLikedItems.count || self.likedTracks.contains(where: \.isPlaceholder)
        self.hasLoadedInitialBatch = true

        if AudioQualitySettings.shared.preloadAllFavoritesInBackground {
            self.startBackgroundCatalogPreload()
        }

        return self.likedTracks
    }

    /// Выбирает случайные треки из всей коллекции «Мне нравится» и подгружает метаданные только для первого чанка (50 шт.),
    /// гарантируя мгновенный старт Shuffle без превышения лимита 40-70 МБ ОЗУ.
    public func fetchRandomLikedTracksForShuffle(limit: Int = 50) async -> [YMTrack] {
        if allLikedItems.isEmpty {
            try? await syncLikes()
        }

        let loadedMap = Dictionary(
            likedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        guard !allLikedItems.isEmpty else {
            return Array(loadedMap.values).shuffled()
        }

        let sampledItems = Array(allLikedItems.shuffled().prefix(limit))
        var result: [YMTrack] = []
        var missingIds: [String] = []

        for item in sampledItems {
            if let existing = loadedMap[item.id] ?? loadedMap[item.trackIdentifier] {
                result.append(existing)
            } else {
                missingIds.append(item.id)
            }
        }

        if !missingIds.isEmpty {
            if let fetched = try? await networkClient.fetchTracks(trackIds: missingIds) {
                result.append(contentsOf: fetched)
            }
        }

        return result.shuffled()
    }

    /// Loads a batch of tracks around the specified trackId as user scrolls past placeholder rows
    public func loadBatchIfNeeded(forTrackId trackId: String) {
        guard let index = likedTracks.firstIndex(where: { $0.id == trackId }) else { return }
        loadBatchIfNeeded(atIndex: index)
    }

    /// Loads a batch of 50 tracks around the given index in likedTracks
    public func loadBatchIfNeeded(atIndex index: Int) {
        guard index >= 0 && index < allLikedItems.count else { return }
        guard index < likedTracks.count && likedTracks[index].isPlaceholder else { return }

        let batchSize = 50
        let batchStart = (index / batchSize) * batchSize
        guard !inFlightBatches.contains(batchStart) else { return }

        inFlightBatches.insert(batchStart)
        let batchEnd = min(batchStart + batchSize, allLikedItems.count)
        let slice = allLikedItems[batchStart..<batchEnd]
        let idsToFetch = slice.map(\.id)

        Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.inFlightBatches.remove(batchStart)
                }
            }

            do {
                let fetchedTracks = try await self.networkClient.fetchTracks(trackIds: idsToFetch)
                let trackMap = Dictionary(fetchedTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

                await MainActor.run {
                    for i in batchStart..<batchEnd {
                        guard i < self.likedTracks.count, i < self.allLikedItems.count else { continue }
                        let item = self.allLikedItems[i]
                        if self.likedTracks[i].isPlaceholder {
                            if let realTrack = trackMap[item.id] {
                                self.likedTracks[i] = realTrack
                            } else {
                                self.likedTracks[i] = YMTrack(
                                    id: item.id,
                                    title: "Недоступный трек",
                                    available: false,
                                    isPlaceholder: false
                                )
                            }
                        }
                    }

                    let existingIds = Set(self.searchCatalog.map(\.id))
                    let unique = fetchedTracks.filter { !existingIds.contains($0.id) }
                    self.searchCatalog.append(contentsOf: unique)
                    self.hasMoreLikes = self.likedTracks.contains { $0.isPlaceholder }
                }
            } catch {
                print("[LikesService] Error loading batch at index \(batchStart): \(error)")
            }
        }
    }

    /// Fetches track immediately if user clicks on a placeholder row before batch arrives
    public func fetchTrackImmediately(trackId: String) async -> YMTrack? {
        let cleanId = extractCleanId(from: trackId)
        if let found = likedTracks.first(where: { !$0.isPlaceholder && (extractCleanId(from: $0.id) == cleanId || $0.id == trackId) }) {
            return found
        }
        do {
            let fetched = try await networkClient.fetchTracks(trackIds: [cleanId])
            if let track = fetched.first {
                if let idx = likedTracks.firstIndex(where: { $0.id == trackId || extractCleanId(from: $0.id) == cleanId }) {
                    likedTracks[idx] = track
                }
                let existingIds = Set(self.searchCatalog.map(\.id))
                if !existingIds.contains(track.id) {
                    self.searchCatalog.append(track)
                }
                return track
            }
        } catch {
            print("[LikesService] Error fetching track immediately: \(error)")
        }
        return nil
    }

    /// Loads the next batch of real tracks from allLikedItems as user scrolls
    public func loadMoreLikedTracks(batchSize: Int = 50) async {
        guard !isLoadingMore else { return }

        // 1. Если после сжатия памяти в likedTracks есть плейсхолдеры — сначала гидрируем их
        if let firstPlaceholderIdx = likedTracks.firstIndex(where: \.isPlaceholder) {
            self.isLoadingMore = true
            defer { self.isLoadingMore = false }

            let batchEnd = min(firstPlaceholderIdx + batchSize, min(likedTracks.count, allLikedItems.count))
            let idsToFetch = (firstPlaceholderIdx..<batchEnd).map { allLikedItems[$0].id }
            do {
                let fetched = try await networkClient.fetchTracks(trackIds: idsToFetch)
                let trackMap = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for i in firstPlaceholderIdx..<batchEnd {
                    let itemId = allLikedItems[i].id
                    if let realTrack = trackMap[itemId] {
                        likedTracks[i] = realTrack
                    }
                }
                let existingIds = Set(self.searchCatalog.map(\.id))
                self.searchCatalog.append(contentsOf: fetched.filter { !existingIds.contains($0.id) })
                self.hasMoreLikes = self.likedTracks.count < self.allLikedItems.count || self.likedTracks.contains(where: \.isPlaceholder)
            } catch {
                print("[LikesService] Error hydrating placeholder tracks: \(error)")
            }
            return
        }

        // 2. Стандартная подгрузка следующих чанков
        let currentCount = likedTracks.count
        guard currentCount < allLikedItems.count else {
            self.hasMoreLikes = false
            return
        }

        self.isLoadingMore = true
        defer { self.isLoadingMore = false }

        let nextEnd = min(currentCount + batchSize, allLikedItems.count)
        let slice = Array(allLikedItems[currentCount..<nextEnd])
        let idsToFetch = slice.map(\.id)

        do {
            let fetched = try await networkClient.fetchTracks(trackIds: idsToFetch)
            self.likedTracks.append(contentsOf: fetched)
            let existingIds = Set(self.searchCatalog.map(\.id))
            self.searchCatalog.append(contentsOf: fetched.filter { !existingIds.contains($0.id) })
            self.hasMoreLikes = self.likedTracks.count < self.allLikedItems.count || self.likedTracks.contains(where: \.isPlaceholder)
        } catch {
            print("[LikesService] Error loading more liked tracks: \(error)")
        }
    }

    /// Starts gentle background preloading of remaining tracks into searchCatalog and updates placeholders
    public func startBackgroundCatalogPreload() {
        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = Task { [weak self] in
            while true {
                guard let self = self else { break }
                guard AudioQualitySettings.shared.preloadAllFavoritesInBackground else { break }

                let (batchIds, isIndexing) = await MainActor.run { () -> ([String], Bool) in
                    let loadedIds = Set(self.likedTracks.filter { !$0.isPlaceholder }.map(\.id)).union(self.searchCatalog.map(\.id))
                    let unindexed = self.allLikedItems.filter { !loadedIds.contains($0.id) }
                    let slice = Array(unindexed.prefix(100)).map(\.id)
                    return (slice, self.isIndexingCatalog)
                }

                guard !batchIds.isEmpty, !isIndexing else { break }

                do {
                    try await Task.sleep(nanoseconds: 150_000_000) // 150ms throttle between batches
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }

                do {
                    let newTracks = try await self.networkClient.fetchTracks(trackIds: batchIds)
                    await MainActor.run {
                        let existingIds = Set(self.searchCatalog.map(\.id)).union(self.likedTracks.filter { !$0.isPlaceholder }.map(\.id))
                        let unique = newTracks.filter { !existingIds.contains($0.id) }
                        self.searchCatalog.append(contentsOf: unique)

                        let trackMap = Dictionary(newTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        for i in 0..<self.likedTracks.count {
                            if self.likedTracks[i].isPlaceholder && i < self.allLikedItems.count {
                                let id = self.allLikedItems[i].id
                                if let loaded = trackMap[id] {
                                    self.likedTracks[i] = loaded
                                }
                            }
                        }
                        self.hasMoreLikes = self.likedTracks.contains { $0.isPlaceholder }
                    }
                } catch {
                    print("[LikesService] Background preload error: \(error)")
                    break
                }
            }
        }
    }

    /// Cancels background preloading and prunes search buffer to release RAM
    public func stopBackgroundCatalogPreloadAndPrune() {
        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = nil
        pruneSearchCatalogIfNeeded()
    }

    /// Rapidly loads all remaining unindexed tracks directly into searchCatalog for comprehensive search
    public func ensureAllLikedTracksLoadedForSearch() async {
        let loadedIds = Set(likedTracks.filter { !$0.isPlaceholder }.map(\.id)).union(searchCatalog.map(\.id))
        guard loadedIds.count < allLikedItems.count else { return }

        self.isIndexingCatalog = true
        backgroundCatalogTask?.cancel()
        defer { self.isIndexingCatalog = false }

        while true {
            let currentLoadedIds = Set(likedTracks.filter { !$0.isPlaceholder }.map(\.id)).union(searchCatalog.map(\.id))
            let unindexed = allLikedItems.filter { !currentLoadedIds.contains($0.id) }
            guard !unindexed.isEmpty else { break }

            let batchIds = Array(unindexed.prefix(100)).map(\.id)
            do {
                let newTracks = try await networkClient.fetchTracks(trackIds: batchIds)
                let existing = Set(self.searchCatalog.map(\.id)).union(self.likedTracks.filter { !$0.isPlaceholder }.map(\.id))
                let unique = newTracks.filter { !existing.contains($0.id) }
                self.searchCatalog.append(contentsOf: unique)

                let trackMap = Dictionary(newTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for i in 0..<self.likedTracks.count {
                    if self.likedTracks[i].isPlaceholder && i < self.allLikedItems.count {
                        let id = self.allLikedItems[i].id
                        if let loaded = trackMap[id] {
                            self.likedTracks[i] = loaded
                        }
                    }
                }
                self.hasMoreLikes = self.likedTracks.contains { $0.isPlaceholder }
            } catch {
                print("[LikesService] Error during search catalog indexing: \(error)")
                break
            }
        }
    }

    /// Searches across the union of visible table tracks and the preloaded search buffer
    public func searchInLikes(query: String) -> [YMTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return likedTracks }

        var seen = Set<String>()
        var combined: [YMTrack] = []
        combined.reserveCapacity(likedTracks.count + searchCatalog.count)

        for track in likedTracks where !track.isPlaceholder {
            if seen.insert(track.id).inserted {
                combined.append(track)
            }
        }
        for track in searchCatalog where !track.isPlaceholder {
            if seen.insert(track.id).inserted {
                combined.append(track)
            }
        }

        return combined.filter { track in
            track.displayTitle.lowercased().contains(q) ||
            track.artistsString.lowercased().contains(q) ||
            (track.primaryAlbumTitle?.lowercased().contains(q) ?? false)
        }
    }

    /// Prunes searchCatalog buffer in eco-mode and compacts likedTracks memory
    public func pruneSearchCatalogIfNeeded() {
        guard !AudioQualitySettings.shared.preloadAllFavoritesInBackground else { return }
        searchCatalog.removeAll(keepingCapacity: false)
        pruneLikedTracksMemory()
    }

    /// Immediately flushes all background search buffers and compacts likedTracks
    public func compressMemory() {
        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = nil
        searchCatalog.removeAll(keepingCapacity: false)
        if !AudioQualitySettings.shared.preloadAllFavoritesInBackground {
            pruneLikedTracksMemory()
        }
    }

    /// Replaces tracks beyond the first 100 with lightweight placeholders to free RAM
    private func pruneLikedTracksMemory() {
        guard likedTracks.count > 100 else { return }
        for i in 100..<likedTracks.count {
            if !likedTracks[i].isPlaceholder && !likedTracks[i].isSpacer {
                let placeholderId = (i < allLikedItems.count) ? allLikedItems[i].trackIdentifier : likedTracks[i].id
                likedTracks[i] = YMTrack.placeholder(id: placeholderId)
            }
        }
        hasMoreLikes = likedTracks.contains { $0.isPlaceholder }
    }

    /// Complete state reset used when signing out
    public func resetAll() {
        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = nil
        inFlightBatches.removeAll()
        allLikedItems.removeAll()
        likedTrackIds.removeAll()
        likedTracks.removeAll()
        searchCatalog.removeAll()
        hasMoreLikes = false
        isLoadingMore = false
        isSyncing = false
        isIndexingCatalog = false
        hasLoadedInitialBatch = false
    }

    /// Toggles like status with optimistic UI update (including removing/inserting in likedTracks table) and rollback on failure
    public func toggleLike(track: YMTrack) async {
        await toggleLike(trackId: track.id, trackObject: track)
    }

    public func toggleLike(trackId: String, trackObject: YMTrack? = nil) async {
        let wasLiked = isLiked(trackId: trackId)
        let cleanId = extractCleanId(from: trackId)

        // Сохраняем снимки для возможного отката при ошибке сети
        let previousLikedIds = self.likedTrackIds
        let previousLikedTracks = self.likedTracks
        let previousAllLikedItems = self.allLikedItems
        let previousSearchCatalog = self.searchCatalog

        // Находим известный albumId для точного запроса к API Яндекса
        let knownTrack = trackObject
            ?? likedTracks.first(where: { !$0.isPlaceholder && ($0.id == cleanId || $0.id == trackId) })
            ?? searchCatalog.first(where: { $0.id == cleanId || $0.id == trackId })
            ?? (AudioPlayerEngine.shared.currentTrack?.id == cleanId ? AudioPlayerEngine.shared.currentTrack : nil)

        let existingItem = allLikedItems.first(where: { $0.id == cleanId || $0.trackIdentifier == trackId })
        let resolvedAlbumId = knownTrack?.primaryAlbumId ?? existingItem?.albumId

        if wasLiked {
            // Оптимистичное удаление из множеств и из таблицы «Мне нравится»
            likedTrackIds.remove(trackId)
            likedTrackIds.remove(cleanId)
            if let albId = resolvedAlbumId {
                likedTrackIds.remove("\(cleanId):\(albId)")
            }

            likedTracks.removeAll { item in
                let itemCleanId = extractCleanId(from: item.id)
                return item.id == trackId || itemCleanId == cleanId
            }
            allLikedItems.removeAll { item in
                item.id == cleanId || item.trackIdentifier == trackId
            }
            searchCatalog.removeAll { item in
                let itemCleanId = extractCleanId(from: item.id)
                return item.id == trackId || itemCleanId == cleanId
            }
            hasMoreLikes = likedTracks.contains { $0.isPlaceholder }
        } else {
            // Оптимистичное добавление в «Мне нравится»
            likedTrackIds.insert(cleanId)
            likedTrackIds.insert(trackId)

            let newItem = YMLikedTrackItem(id: cleanId, albumId: resolvedAlbumId)
            if !allLikedItems.contains(where: { $0.id == cleanId }) {
                allLikedItems.insert(newItem, at: 0)
            }

            if let trackToInsert = knownTrack, !trackToInsert.isPlaceholder {
                if !likedTracks.contains(where: { extractCleanId(from: $0.id) == cleanId }) {
                    likedTracks.insert(trackToInsert, at: 0)
                }
            } else if !likedTracks.isEmpty {
                // Если полная структура трека ещё не передана, вставляем плейсхолдер и сразу подгружаем его
                let placeholder = YMTrack.placeholder(id: newItem.trackIdentifier)
                likedTracks.insert(placeholder, at: 0)
                Task {
                    _ = await self.fetchTrackImmediately(trackId: cleanId)
                }
            }
        }

        do {
            if wasLiked {
                try await removeLike(trackId: cleanId, albumId: resolvedAlbumId)
            } else {
                try await addLike(trackId: cleanId, albumId: resolvedAlbumId)
            }
        } catch {
            // Откат состояния при сетевой ошибке
            print("[LikesService] Failed to toggle like for \(trackId): \(error). Rolling back state...")
            self.likedTrackIds = previousLikedIds
            self.likedTracks = previousLikedTracks
            self.allLikedItems = previousAllLikedItems
            self.searchCatalog = previousSearchCatalog
            self.hasMoreLikes = self.likedTracks.contains { $0.isPlaceholder }
        }
    }

    private func addLike(trackId: String, albumId: String? = nil) async throws {
        guard let uid = AuthService.shared.currentUser?.userId ?? keychain.getUserId() else { return }
        let cleanId = extractCleanId(from: trackId)
        let escapedUid = YMNetworkClient.escapePath(uid)

        let cleanBody = "track-ids=\(cleanId)".data(using: .utf8)
        do {
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                method: "POST",
                body: cleanBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"]
            )
            return
        } catch {
            print("[LikesService] Clean ID add-multiple failed: \(error). Trying album ID format...")
        }

        if let albumId = albumId, !albumId.isEmpty {
            let albumBody = "track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            do {
                let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                    endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                    method: "POST",
                    body: albumBody,
                    headers: ["Content-Type": "application/x-www-form-urlencoded"]
                )
                return
            } catch {
                print("[LikesService] Album ID add-multiple failed: \(error). Trying multi-param format...")
            }

            let jointBody = "track-ids=\(cleanId)&track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                method: "POST",
                body: jointBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"]
            )
        }
    }

    private func removeLike(trackId: String, albumId: String? = nil) async throws {
        guard let uid = AuthService.shared.currentUser?.userId ?? keychain.getUserId() else { return }
        let cleanId = extractCleanId(from: trackId)
        let escapedUid = YMNetworkClient.escapePath(uid)

        // В Yandex Music API эндпоинт для снятия отметки «Мне нравится» — строго /remove (НЕ /remove-multiple)
        // 1. Сначала отправляем чистый числовой ID трека, так как именно он хранится в базе библиотеки
        let cleanBody = "track-ids=\(cleanId)".data(using: .utf8)
        do {
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/remove",
                method: "POST",
                body: cleanBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            return
        } catch {
            print("[LikesService] Clean ID /remove failed: \(error). Trying joint format...")
        }

        // 2. Если трек был добавлен с привязкой к альбому, пробуем составной ID cleanId:albumId
        if let albumId = albumId, !albumId.isEmpty {
            let albumBody = "track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            do {
                let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                    endpoint: "/users/\(escapedUid)/likes/tracks/remove",
                    method: "POST",
                    body: albumBody,
                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
                return
            } catch {
                print("[LikesService] Album ID /remove failed: \(error). Trying multi-param format...")
            }

            // 3. Пробуем передать оба формата через x-www-form-urlencoded (&track-ids=...)
            let jointBody = "track-ids=\(cleanId)&track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/remove",
                method: "POST",
                body: jointBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        }
    }
}
