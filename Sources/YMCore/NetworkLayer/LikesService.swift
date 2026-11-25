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

    @ObservationIgnored
    private var syncGeneration: UInt64 = 0

    @ObservationIgnored
    private var unresolvableTrackIds: Set<String> = []

    public private(set) var hasMoreLikes: Bool = false
    public private(set) var isLoadingMore: Bool = false
    public private(set) var isSyncing: Bool = false
    public private(set) var isIndexingCatalog: Bool = false
    public private(set) var hasLoadedInitialBatch: Bool = false

    private var allLikedItems: [YMLikedTrackItem] = []
    private var nextLikedItemCursor: Int = 0
    private var inFlightBatches: Set<Int> = []
    private var loadMoreTask: Task<Void, Never>?
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

    private func recomputeHasMoreLikes() {
        hasMoreLikes = nextLikedItemCursor < allLikedItems.count || likedTracks.contains(where: \.isPlaceholder)
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
        recomputeHasMoreLikes()
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

        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil

        syncGeneration &+= 1
        let generation = syncGeneration

        self.isSyncing = true
        defer { self.isSyncing = false }

        let response: YMLikesLibraryResponse = try await networkClient.request(
            endpoint: "/users/\(YMNetworkClient.escapePath(resolvedUid))/likes/tracks",
            cachePolicy: .reloadIgnoringLocalCacheData
        )

        guard self.syncGeneration == generation else { return self.likedTracks }

        self.allLikedItems = response.allLikedItems
        self.likedTrackIds = Set(allLikedItems.map(\.id))
        self.searchCatalog = []
        self.inFlightBatches.removeAll()
        self.unresolvableTrackIds.removeAll()
        self.nextLikedItemCursor = 0

        guard !allLikedItems.isEmpty else {
            self.likedTracks = []
            self.hasMoreLikes = false
            self.hasLoadedInitialBatch = true
            return []
        }

        let initialBatchSize = min(initialLimit, allLikedItems.count)
        let initialSlice = Array(allLikedItems.prefix(initialBatchSize))
        let idsToFetch = initialSlice.map { extractCleanId(from: $0.id) }

        let fullTracks = try await networkClient.fetchTracks(trackIds: idsToFetch)
        guard self.syncGeneration == generation else { return self.likedTracks }

        let trackMap = Dictionary(fullTracks.map { (extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })

        var assembled: [YMTrack] = []
        assembled.reserveCapacity(initialBatchSize)

        for item in initialSlice {
            let clean = extractCleanId(from: item.id)
            if let track = trackMap[clean] {
                assembled.append(track)
            } else {
                self.unresolvableTrackIds.insert(clean)
                assembled.append(
                    YMTrack(
                        id: item.id,
                        title: "Недоступный трек",
                        available: false,
                        isPlaceholder: false
                    )
                )
            }
        }

        self.likedTracks = assembled
        self.nextLikedItemCursor = initialBatchSize
        self.searchCatalog = fullTracks
        self.hasLoadedInitialBatch = true
        recomputeHasMoreLikes()

        if AudioQualitySettings.shared.preloadAllFavoritesInBackground {
            self.startBackgroundCatalogPreload()
        }

        return self.likedTracks
    }

    /// Выбирает случайные треки из всей коллекции «Мне нравится» и подгружает метаданные только для чанка (50 шт.),
    /// гарантируя мгновенный старт Shuffle без превышения лимита 40-70 МБ ОЗУ.
    public func fetchRandomLikedTracksForShuffle(limit: Int = 50) async -> [YMTrack] {
        await fetchMoreRandomLikedTracksForShuffle(excludingIds: [], limit: limit)
    }

    /// Выбирает следующую порцию случайных ещё не добавленных в очередь треков из всей коллекции «Мне нравится».
    public func fetchMoreRandomLikedTracksForShuffle(excludingIds: Set<String>, limit: Int = 50) async -> [YMTrack] {
        if allLikedItems.isEmpty {
            try? await syncLikes()
        }

        let loadedMap = Dictionary(
            likedTracks.filter { !$0.isPlaceholder && !$0.isSpacer }.map { (extractCleanId(from: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let remainingItems = allLikedItems.filter { item in
            let cleanId = extractCleanId(from: item.id)
            return !excludingIds.contains(item.id)
                && !excludingIds.contains(item.trackIdentifier)
                && !excludingIds.contains(cleanId)
                && !unresolvableTrackIds.contains(cleanId)
        }

        guard !remainingItems.isEmpty else {
            return []
        }

        let sampledItems = Array(remainingItems.shuffled().prefix(limit))
        var result: [YMTrack] = []
        var missingIds: [String] = []

        for item in sampledItems {
            let cleanId = extractCleanId(from: item.id)
            if let existing = loadedMap[cleanId] {
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

    /// Returns the next batch of sequential liked tracks not yet present in `excludingIds`,
    /// automatically loading the next 50-track page from the API when needed.
    public func loadNextLikedTracksForPlayback(excludingIds: Set<String>, batchSize: Int = 50) async -> [YMTrack] {
        func collectNewTracks() -> [YMTrack] {
            likedTracks.filter { track in
                guard !track.isPlaceholder && !track.isSpacer else { return false }
                let cleanId = extractCleanId(from: track.id)
                return !excludingIds.contains(track.id) && !excludingIds.contains(cleanId)
            }
        }

        let alreadyLoaded = collectNewTracks()
        if !alreadyLoaded.isEmpty {
            return alreadyLoaded
        }

        guard hasMoreLikes || nextLikedItemCursor < allLikedItems.count || likedTracks.contains(where: \.isPlaceholder) else {
            return []
        }

        await loadMoreLikedTracks(batchSize: batchSize)
        return collectNewTracks()
    }

    /// Loads a batch of tracks around the specified trackId as user scrolls past placeholder rows
    public func loadBatchIfNeeded(forTrackId trackId: String) {
        guard let index = likedTracks.firstIndex(where: { $0.id == trackId }) else { return }
        loadBatchIfNeeded(atIndex: index)
    }

    /// Loads a batch of 50 tracks around the given index in likedTracks
    public func loadBatchIfNeeded(atIndex index: Int) {
        guard index >= 0 && index < likedTracks.count else { return }
        guard likedTracks[index].isPlaceholder else { return }

        let batchSize = 50
        let batchStart = (index / batchSize) * batchSize
        guard !inFlightBatches.contains(batchStart) else { return }

        inFlightBatches.insert(batchStart)
        let batchEnd = min(batchStart + batchSize, likedTracks.count)
        let sliceTracks = likedTracks[batchStart..<batchEnd]
        let placeholderTrackCleanIds = sliceTracks.compactMap { track -> String? in
            guard track.isPlaceholder else { return nil }
            let clean = extractCleanId(from: track.id)
            return unresolvableTrackIds.contains(clean) ? nil : clean
        }

        guard !placeholderTrackCleanIds.isEmpty else {
            inFlightBatches.remove(batchStart)
            return
        }

        let generation = syncGeneration

        Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor [weak self] in
                    self?.inFlightBatches.remove(batchStart)
                }
            }

            do {
                let fetchedTracks = try await self.networkClient.fetchTracks(trackIds: placeholderTrackCleanIds)
                let trackMap = Dictionary(fetchedTracks.map { (self.extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })

                await MainActor.run {
                    guard self.syncGeneration == generation else { return }
                    for i in batchStart..<min(batchEnd, self.likedTracks.count) {
                        if self.likedTracks[i].isPlaceholder {
                            let cleanId = self.extractCleanId(from: self.likedTracks[i].id)
                            if let realTrack = trackMap[cleanId] {
                                self.likedTracks[i] = realTrack
                            } else if !self.unresolvableTrackIds.contains(cleanId) {
                                self.unresolvableTrackIds.insert(cleanId)
                                self.likedTracks[i] = YMTrack(
                                    id: self.likedTracks[i].id,
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
                    self.recomputeHasMoreLikes()
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

    /// Loads the next batch of real tracks from allLikedItems as user scrolls or skips ahead
    public func loadMoreLikedTracks(batchSize: Int = 50) async {
        if let existingTask = loadMoreTask {
            await existingTask.value
            return
        }

        let generation = self.syncGeneration
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isLoadingMore = true
            defer {
                self.isLoadingMore = false
                self.loadMoreTask = nil
            }

            // 1. Если после сжатия памяти в likedTracks есть плейсхолдеры — сначала гидрируем их
            if let firstPlaceholderIdx = self.likedTracks.firstIndex(where: \.isPlaceholder) {
                let batchEnd = min(firstPlaceholderIdx + batchSize, self.likedTracks.count)
                let placeholderCleanIds = (firstPlaceholderIdx..<batchEnd).compactMap { i -> String? in
                    guard self.likedTracks[i].isPlaceholder else { return nil }
                    let clean = self.extractCleanId(from: self.likedTracks[i].id)
                    return self.unresolvableTrackIds.contains(clean) ? nil : clean
                }

                guard !placeholderCleanIds.isEmpty else {
                    self.recomputeHasMoreLikes()
                    return
                }

                do {
                    let fetched = try await self.networkClient.fetchTracks(trackIds: placeholderCleanIds)
                    guard self.syncGeneration == generation else { return }

                    let trackMap = Dictionary(fetched.map { (self.extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
                    for i in firstPlaceholderIdx..<min(batchEnd, self.likedTracks.count) {
                        if self.likedTracks[i].isPlaceholder {
                            let cleanId = self.extractCleanId(from: self.likedTracks[i].id)
                            if let realTrack = trackMap[cleanId] {
                                self.likedTracks[i] = realTrack
                            } else {
                                self.unresolvableTrackIds.insert(cleanId)
                                self.likedTracks[i] = YMTrack(
                                    id: self.likedTracks[i].id,
                                    title: "Недоступный трек",
                                    available: false,
                                    isPlaceholder: false
                                )
                            }
                        }
                    }
                    let existingIds = Set(self.searchCatalog.map(\.id))
                    self.searchCatalog.append(contentsOf: fetched.filter { !existingIds.contains($0.id) })
                    self.recomputeHasMoreLikes()
                } catch {
                    print("[LikesService] Error hydrating placeholder tracks: \(error)")
                }
                return
            }

            // 2. Стандартная подгрузка следующих чанков по курсору allLikedItems
            let cursor = self.nextLikedItemCursor
            guard cursor < self.allLikedItems.count else {
                self.nextLikedItemCursor = self.allLikedItems.count
                self.hasMoreLikes = false
                return
            }

            let nextEnd = min(cursor + batchSize, self.allLikedItems.count)
            let slice = Array(self.allLikedItems[cursor..<nextEnd])
            let idsToFetch = slice.map { self.extractCleanId(from: $0.id) }

            do {
                let fetched = try await self.networkClient.fetchTracks(trackIds: idsToFetch)
                guard self.syncGeneration == generation else { return }

                let trackMap = Dictionary(fetched.map { (self.extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })

                var sliceTracks: [YMTrack] = []
                sliceTracks.reserveCapacity(slice.count)
                for item in slice {
                    let cleanId = self.extractCleanId(from: item.id)
                    if let track = trackMap[cleanId] {
                        sliceTracks.append(track)
                    } else {
                        self.unresolvableTrackIds.insert(cleanId)
                        sliceTracks.append(
                            YMTrack(
                                id: item.id,
                                title: "Недоступный трек",
                                available: false,
                                isPlaceholder: false
                            )
                        )
                    }
                }

                self.likedTracks.append(contentsOf: sliceTracks)
                self.nextLikedItemCursor = nextEnd

                let existingCatalogIds = Set(self.searchCatalog.map(\.id))
                self.searchCatalog.append(contentsOf: fetched.filter { !existingCatalogIds.contains($0.id) })
                self.recomputeHasMoreLikes()
            } catch {
                print("[LikesService] Error loading more liked tracks: \(error)")
            }
        }

        self.loadMoreTask = task
        await task.value
    }

    /// Starts gentle background preloading of remaining tracks into searchCatalog and updates placeholders
    public func startBackgroundCatalogPreload() {
        backgroundCatalogTask?.cancel()
        let generation = self.syncGeneration
        backgroundCatalogTask = Task { [weak self] in
            while true {
                guard let self = self else { break }
                guard AudioQualitySettings.shared.preloadAllFavoritesInBackground else { break }

                let (batchIds, isIndexing) = await MainActor.run { () -> ([String], Bool) in
                    guard self.syncGeneration == generation else { return ([], true) }
                    let loadedIds = Set(self.likedTracks.filter { !$0.isPlaceholder }.map { self.extractCleanId(from: $0.id) })
                        .union(self.searchCatalog.map { self.extractCleanId(from: $0.id) })
                        .union(self.unresolvableTrackIds)

                    let unindexed = self.allLikedItems.compactMap { item -> String? in
                        let clean = self.extractCleanId(from: item.id)
                        return loadedIds.contains(clean) ? nil : clean
                    }
                    var uniqueBatch: [String] = []
                    var seen = Set<String>()
                    for id in unindexed {
                        if seen.insert(id).inserted {
                            uniqueBatch.append(id)
                            if uniqueBatch.count == 100 { break }
                        }
                    }
                    return (uniqueBatch, self.isIndexingCatalog)
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
                        guard self.syncGeneration == generation else { return }
                        let trackMap = Dictionary(newTracks.map { (self.extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
                        let returnedCleanIds = Set(trackMap.keys)

                        for reqId in batchIds {
                            if !returnedCleanIds.contains(reqId) {
                                self.unresolvableTrackIds.insert(reqId)
                            }
                        }

                        let existingIds = Set(self.searchCatalog.map { self.extractCleanId(from: $0.id) })
                            .union(self.likedTracks.filter { !$0.isPlaceholder }.map { self.extractCleanId(from: $0.id) })
                        let unique = newTracks.filter { !existingIds.contains(self.extractCleanId(from: $0.id)) }
                        self.searchCatalog.append(contentsOf: unique)

                        for i in 0..<self.likedTracks.count {
                            if self.likedTracks[i].isPlaceholder {
                                let cleanId = self.extractCleanId(from: self.likedTracks[i].id)
                                if let loaded = trackMap[cleanId] {
                                    self.likedTracks[i] = loaded
                                } else if self.unresolvableTrackIds.contains(cleanId) {
                                    self.likedTracks[i] = YMTrack(
                                        id: self.likedTracks[i].id,
                                        title: "Недоступный трек",
                                        available: false,
                                        isPlaceholder: false
                                    )
                                }
                            }
                        }
                        self.recomputeHasMoreLikes()
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
        let loadedIds = Set(likedTracks.filter { !$0.isPlaceholder }.map { extractCleanId(from: $0.id) })
            .union(searchCatalog.map { extractCleanId(from: $0.id) })
            .union(unresolvableTrackIds)
        guard loadedIds.count < allLikedItems.count else { return }

        self.isIndexingCatalog = true
        backgroundCatalogTask?.cancel()
        defer { self.isIndexingCatalog = false }

        let generation = self.syncGeneration

        while true {
            guard self.syncGeneration == generation else { break }

            let currentLoadedIds = Set(likedTracks.filter { !$0.isPlaceholder }.map { extractCleanId(from: $0.id) })
                .union(searchCatalog.map { extractCleanId(from: $0.id) })
                .union(unresolvableTrackIds)

            let unindexed = allLikedItems.compactMap { item -> String? in
                let clean = extractCleanId(from: item.id)
                return currentLoadedIds.contains(clean) ? nil : clean
            }
            var batchIds: [String] = []
            var seen = Set<String>()
            for id in unindexed {
                if seen.insert(id).inserted {
                    batchIds.append(id)
                    if batchIds.count == 100 { break }
                }
            }
            guard !batchIds.isEmpty else { break }

            do {
                let newTracks = try await networkClient.fetchTracks(trackIds: batchIds)
                guard self.syncGeneration == generation else { break }

                let trackMap = Dictionary(newTracks.map { (extractCleanId(from: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
                let returnedCleanIds = Set(trackMap.keys)

                for reqId in batchIds {
                    if !returnedCleanIds.contains(reqId) {
                        self.unresolvableTrackIds.insert(reqId)
                    }
                }

                let existing = Set(self.searchCatalog.map { extractCleanId(from: $0.id) })
                    .union(self.likedTracks.filter { !$0.isPlaceholder }.map { extractCleanId(from: $0.id) })
                let unique = newTracks.filter { !existing.contains(extractCleanId(from: $0.id)) }
                self.searchCatalog.append(contentsOf: unique)

                for i in 0..<self.likedTracks.count {
                    if self.likedTracks[i].isPlaceholder {
                        let cleanId = self.extractCleanId(from: self.likedTracks[i].id)
                        if let loaded = trackMap[cleanId] {
                            self.likedTracks[i] = loaded
                        } else if self.unresolvableTrackIds.contains(cleanId) {
                            self.likedTracks[i] = YMTrack(
                                id: self.likedTracks[i].id,
                                title: "Недоступный трек",
                                available: false,
                                isPlaceholder: false
                            )
                        }
                    }
                }
                self.recomputeHasMoreLikes()
            } catch {
                print("[LikesService] Error during search catalog indexing: \(error)")
                break
            }
        }
    }

    /// Searches across the union of visible table tracks and the preloaded search buffer
    public func searchInLikes(query: String) -> [YMTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            track.displayTitle.localizedCaseInsensitiveContains(q) ||
            track.artists.contains { $0.name.localizedCaseInsensitiveContains(q) } ||
            (track.artists.isEmpty && track.artistsString.localizedCaseInsensitiveContains(q)) ||
            (track.primaryAlbumTitle?.localizedCaseInsensitiveContains(q) ?? false)
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
                likedTracks[i] = YMTrack.placeholder(id: likedTracks[i].id)
            }
        }
        recomputeHasMoreLikes()
    }

    /// Complete state reset used when signing out
    public func resetAll() {
        syncGeneration &+= 1
        backgroundCatalogTask?.cancel()
        backgroundCatalogTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        nextLikedItemCursor = 0
        inFlightBatches.removeAll()
        allLikedItems.removeAll()
        likedTrackIds.removeAll()
        likedTracks.removeAll()
        searchCatalog.removeAll()
        unresolvableTrackIds.removeAll()
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
        let previousCursor = self.nextLikedItemCursor

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

            if let removedIndex = allLikedItems.firstIndex(where: { $0.id == cleanId || $0.trackIdentifier == trackId }) {
                allLikedItems.remove(at: removedIndex)
                if removedIndex < nextLikedItemCursor {
                    nextLikedItemCursor = max(0, nextLikedItemCursor - 1)
                }
            }

            searchCatalog.removeAll { item in
                let itemCleanId = extractCleanId(from: item.id)
                return item.id == trackId || itemCleanId == cleanId
            }
            recomputeHasMoreLikes()
        } else {
            // Оптимистичное добавление в «Мне нравится»
            likedTrackIds.insert(cleanId)
            likedTrackIds.insert(trackId)

            let newItem = YMLikedTrackItem(id: cleanId, albumId: resolvedAlbumId)
            if !allLikedItems.contains(where: { $0.id == cleanId }) {
                allLikedItems.insert(newItem, at: 0)
                if hasLoadedInitialBatch {
                    nextLikedItemCursor += 1
                }
            }

            if let trackToInsert = knownTrack, !trackToInsert.isPlaceholder {
                if !likedTracks.contains(where: { extractCleanId(from: $0.id) == cleanId }) {
                    likedTracks.insert(trackToInsert, at: 0)
                }
            } else if !likedTracks.isEmpty {
                let placeholder = YMTrack.placeholder(id: newItem.trackIdentifier)
                likedTracks.insert(placeholder, at: 0)
                Task {
                    _ = await self.fetchTrackImmediately(trackId: cleanId)
                }
            }
            recomputeHasMoreLikes()
        }

        if let current = AudioPlayerEngine.shared.currentTrack, extractCleanId(from: current.id) == cleanId {
            RemoteCommandManager.shared.updateLikeState(isLiked: isLiked(trackId: cleanId))
        }

        do {
            if wasLiked {
                try await removeLike(trackId: cleanId, albumId: resolvedAlbumId)
            } else {
                try await addLike(trackId: cleanId, albumId: resolvedAlbumId)
                if AudioPlayerEngine.shared.isWaveMode, let trackToNotify = knownTrack {
                    AudioPlayerEngine.shared.onWaveTrackOutcome?(trackToNotify, .liked)
                }
            }
        } catch {
            print("[LikesService] Failed to toggle like for \(trackId): \(error). Rolling back state...")
            self.likedTrackIds = previousLikedIds
            self.likedTracks = previousLikedTracks
            self.allLikedItems = previousAllLikedItems
            self.searchCatalog = previousSearchCatalog
            self.nextLikedItemCursor = previousCursor
            recomputeHasMoreLikes()

            if let current = AudioPlayerEngine.shared.currentTrack, extractCleanId(from: current.id) == cleanId {
                RemoteCommandManager.shared.updateLikeState(isLiked: isLiked(trackId: cleanId))
            }
        }
    }

    private func addLike(trackId: String, albumId: String? = nil) async throws {
        guard let uid = AuthService.shared.currentUser?.userId ?? keychain.getUserId() else {
            throw YMAPIError.unauthorized
        }
        let cleanId = extractCleanId(from: trackId)
        let escapedUid = YMNetworkClient.escapePath(uid)

        let cleanBody = "track-ids=\(cleanId)".data(using: .utf8)
        var lastError: Error?
        do {
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                method: "POST",
                body: cleanBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            return
        } catch {
            if error is CancellationError { throw error }
            if let apiErr = error as? YMAPIError, case .unauthorized = apiErr { throw error }
            lastError = error
            print("[LikesService] Clean ID add-multiple failed: \(error). Trying album ID format...")
        }

        if let albumId = albumId, !albumId.isEmpty {
            let albumBody = "track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            do {
                let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                    endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                    method: "POST",
                    body: albumBody,
                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
                return
            } catch {
                if error is CancellationError { throw error }
                if let apiErr = error as? YMAPIError, case .unauthorized = apiErr { throw error }
                lastError = error
                print("[LikesService] Album ID add-multiple failed: \(error). Trying multi-param format...")
            }

            let jointBody = "track-ids=\(cleanId)&track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/add-multiple",
                method: "POST",
                body: jointBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } else if let lastError {
            throw lastError
        }
    }

    private func removeLike(trackId: String, albumId: String? = nil) async throws {
        guard let uid = AuthService.shared.currentUser?.userId ?? keychain.getUserId() else {
            throw YMAPIError.unauthorized
        }
        let cleanId = extractCleanId(from: trackId)
        let escapedUid = YMNetworkClient.escapePath(uid)

        let cleanBody = "track-ids=\(cleanId)".data(using: .utf8)
        var lastError: Error?
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
            if error is CancellationError { throw error }
            if let apiErr = error as? YMAPIError, case .unauthorized = apiErr { throw error }
            lastError = error
            print("[LikesService] Clean ID /remove failed: \(error). Trying joint format...")
        }

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
                if error is CancellationError { throw error }
                if let apiErr = error as? YMAPIError, case .unauthorized = apiErr { throw error }
                lastError = error
                print("[LikesService] Album ID /remove failed: \(error). Trying multi-param format...")
            }

            let jointBody = "track-ids=\(cleanId)&track-ids=\(cleanId):\(albumId)".data(using: .utf8)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/users/\(escapedUid)/likes/tracks/remove",
                method: "POST",
                body: jointBody,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } else if let lastError {
            throw lastError
        }
    }
}
