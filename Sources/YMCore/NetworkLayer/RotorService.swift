import Foundation

/// Rotor Station ("Моя волна") Service actor.
/// Supports Rotor Session v2 (POST /rotor/session/new, /tracks, /feedback) with structured 4-level fallback to Rotor v1.
/// Manages batch fetching, queue pagination, strict deduplication, session history, wave vibes,
/// personal wave recommendations, diagnostics telemetry, and radio feedback events.
public actor RotorService {
    public static let shared = RotorService()

    private static let apiModeDefaultsKey = "ym_rotor_api_mode"

    private let networkClient: YMNetworkClient
    private var currentSessionId: String?
    private var currentBatchId: String?
    private var sessionGeneration: UInt64 = 0
    private var activeV1StationId: String? = nil
    private var isUsingV1Protocol: Bool = false
    private var seenTrackIds: Set<String> = []
    private var seenTrackIdList: [String] = []
    private var recentQueueIdentifiers: [String] = []
    private let isoFormatter: ISO8601DateFormatter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var activeContext: YMWaveContext = .myWaveDefault
    private var activeVibe: YMWaveVibePreset = .defaultWave
    private var activeExcludedTrackIds: Set<String> = []

    public private(set) var diagnostics: YMRotorDiagnostics = YMRotorDiagnostics()
    public var preferredAPIMode: YMRotorAPIMode {
        didSet {
            UserDefaults.standard.set(preferredAPIMode.rawValue, forKey: Self.apiModeDefaultsKey)
            let updatedMode = preferredAPIMode
            Task { @MainActor in
                if RotorDiagnosticsStore.shared.preferredAPIMode != updatedMode {
                    RotorDiagnosticsStore.shared.preferredAPIMode = updatedMode
                }
            }
        }
    }

    // 15-minute in-memory caches for personalized dashboard waves and on-demand full catalog
    private var cachedRecommendedWaves: [YMPersonalWaveStation] = []
    private var recommendedWavesCachedAt: Date? = nil
    private var cachedCatalogWaves: [YMPersonalWaveStation] = []
    private var catalogWavesCachedAt: Date? = nil
    private let recommendedWavesTTL: TimeInterval = 15 * 60

    public init(networkClient: YMNetworkClient = .shared) {
        self.networkClient = networkClient
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter

        if let raw = UserDefaults.standard.string(forKey: Self.apiModeDefaultsKey),
           let saved = YMRotorAPIMode(rawValue: raw) {
            self.preferredAPIMode = saved
        } else {
            self.preferredAPIMode = .auto
        }
    }

    public func setPreferredAPIMode(_ mode: YMRotorAPIMode) {
        self.preferredAPIMode = mode
    }

    public func getPreferredAPIMode() -> YMRotorAPIMode {
        preferredAPIMode
    }

    public func getDiagnostics() -> YMRotorDiagnostics {
        diagnostics
    }

    public func getActiveContext() -> YMWaveContext {
        activeContext
    }

    public func getActiveVibe() -> YMWaveVibePreset {
        activeVibe
    }

    public func getCurrentSessionId() -> String? {
        currentSessionId
    }

    public func setSessionId(_ sessionId: String?) {
        self.currentSessionId = sessionId
    }

    public func getCurrentBatchId() -> String? {
        currentBatchId
    }

    public func setBatchId(_ batchId: String?) {
        self.currentBatchId = batchId
    }

    public func resetSession() {
        self.sessionGeneration &+= 1
        self.currentSessionId = nil
        self.currentBatchId = nil
        self.activeV1StationId = nil
        self.isUsingV1Protocol = false
        self.activeExcludedTrackIds.removeAll()
        self.seenTrackIds.removeAll()
        self.seenTrackIdList.removeAll()
        self.recentQueueIdentifiers.removeAll()
        self.diagnostics = YMRotorDiagnostics()
        publishDiagnostics()
    }

    // MARK: - Personal Waves Discovery

    /// Fetches ONLY personalized wave stations from `GET /rotor/stations/dashboard` (up to 14 unique cards,
    /// excluding `user:onyourwave`). Falls back to `GET /rotor/stations/list` (max 6 popular stations)
    /// strictly as an emergency fallback if the dashboard fails or returns fewer than 3 cards.
    /// Cached in actor memory for 15 minutes to stay well within the 40–65 MB RAM budget.
    public func fetchRecommendedWaves(forceRefresh: Bool = false) async -> [YMPersonalWaveStation] {
        if !forceRefresh,
           !cachedRecommendedWaves.isEmpty,
           let cachedAt = recommendedWavesCachedAt,
           Date().timeIntervalSince(cachedAt) < recommendedWavesTTL {
            return cachedRecommendedWaves
        }

        var stations: [YMPersonalWaveStation] = []
        var seenIds: Set<String> = ["user:onyourwave"]
        let maxDashboardStations = 14

        // 1. Personalized dashboard stations only
        do {
            let dashboard: YMRotorDashboardResponse = try await networkClient.request(
                endpoint: "/rotor/stations/dashboard",
                cachePolicy: .useProtocolCachePolicy
            )
            for item in dashboard.stations {
                if let station = item.toPersonalWaveStation(),
                   !seenIds.contains(station.id) {
                    seenIds.insert(station.id)
                    stations.append(station)
                    if stations.count >= maxDashboardStations { break }
                }
            }
        } catch {
            print("[RotorService] Dashboard fetch failed: \(error.localizedDescription)")
        }

        // 2. Emergency fallback ONLY if dashboard failed or returned fewer than 3 cards (cap at 6)
        if stations.count < 3 {
            do {
                let listItems: [YMRotorDashboardStationItem] = try await networkClient.request(
                    endpoint: "/rotor/stations/list",
                    queryItems: [URLQueryItem(name: "language", value: "ru")],
                    cachePolicy: .useProtocolCachePolicy
                )
                for item in listItems {
                    if let station = item.toPersonalWaveStation(),
                       !seenIds.contains(station.id) {
                        seenIds.insert(station.id)
                        stations.append(station)
                        if stations.count >= 6 { break }
                    }
                }
            } catch {
                print("[RotorService] Emergency stations list fallback failed: \(error.localizedDescription)")
            }
        }

        if !stations.isEmpty {
            self.cachedRecommendedWaves = stations
            self.recommendedWavesCachedAt = Date()
        }
        return stations
    }

    /// Loads the full Yandex Music Rotor stations catalog (`GET /rotor/stations/list`) on explicit user demand
    /// (when opening the "Все жанры" sheet). Cached in actor memory for 15 minutes.
    public func fetchAllCatalogWaves(forceRefresh: Bool = false) async -> [YMPersonalWaveStation] {
        if !forceRefresh,
           !cachedCatalogWaves.isEmpty,
           let cachedAt = catalogWavesCachedAt,
           Date().timeIntervalSince(cachedAt) < recommendedWavesTTL {
            return cachedCatalogWaves
        }

        var stations: [YMPersonalWaveStation] = []
        var seenIds: Set<String> = ["user:onyourwave"]

        do {
            let listItems: [YMRotorDashboardStationItem] = try await networkClient.request(
                endpoint: "/rotor/stations/list",
                queryItems: [URLQueryItem(name: "language", value: "ru")],
                cachePolicy: .useProtocolCachePolicy
            )
            for item in listItems {
                if let station = item.toPersonalWaveStation(),
                   !seenIds.contains(station.id) {
                    seenIds.insert(station.id)
                    stations.append(station)
                }
            }
        } catch {
            print("[RotorService] Full catalog stations fetch failed: \(error.localizedDescription)")
        }

        if !stations.isEmpty {
            self.cachedCatalogWaves = stations
            self.catalogWavesCachedAt = Date()
        }
        return stations
    }

    // MARK: - Station Loading (4-Level Fallback Chain)

    /// Starts "Моя волна" station using Rotor Session v2 with structured fallback to v1.
    /// Resets duplicate tracking and session history.
    public func startWave(
        context: YMWaveContext = .myWaveDefault,
        vibe: YMWaveVibePreset? = nil,
        excludedTrackIds: Set<String> = []
    ) async throws -> [YMTrack] {
        resetSession()
        let gen = sessionGeneration
        self.activeContext = context
        self.activeVibe = vibe ?? .defaultWave
        self.activeExcludedTrackIds = Set(excludedTrackIds.map { $0.components(separatedBy: ":").first ?? $0 })

        var effectiveSeeds: [String] = []
        var seenSeedSet = Set<String>()
        for seed in context.seeds where !seed.isEmpty {
            if seenSeedSet.insert(seed).inserted {
                effectiveSeeds.append(seed)
            }
        }
        if let vibeSeed = activeVibe.seedParameter, !seenSeedSet.contains(vibeSeed) {
            effectiveSeeds.append(vibeSeed)
            seenSeedSet.insert(vibeSeed)
        }

        var lastFallbackReason: String? = nil
        var lastError: Error? = nil

        // Level 1: Primary Rotor Session v2 (POST /rotor/session/new)
        if preferredAPIMode != .v1Fallback {
            do {
                let requestPayload = YMRotorSessionNewRequest(seeds: effectiveSeeds)
                let body = try encoder.encode(requestPayload)

                let result: YMRotorStationTracksResult = try await networkClient.request(
                    endpoint: "/rotor/session/new",
                    method: "POST",
                    body: body,
                    headers: ["Content-Type": "application/json"],
                    cachePolicy: .reloadIgnoringLocalCacheData
                )

                guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

                recordTrackInsights(from: result.sequence)
                let rawTracks = result.sequence.compactMap(\.track)
                let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
                let uniqueTracks = filterExcludedTracks(dedupedTracks)
                if !uniqueTracks.isEmpty {
                    self.currentSessionId = result.radioSessionId
                    self.currentBatchId = result.batchId
                    self.isUsingV1Protocol = false
                    self.activeV1StationId = nil
                    updateDiagnostics(
                        activeProtocol: "Rotor Session v2 (POST /rotor/session/new)",
                        isFallbackActive: false,
                        activeLevel: 1,
                        activeSeeds: effectiveSeeds,
                        fetchedDelta: uniqueTracks.count,
                        duplicatesDelta: duplicatesFiltered,
                        lastFallbackReason: nil
                    )

                    try? await sendFeedback(type: .radioStarted, trackId: nil)
                    return uniqueTracks
                } else {
                    lastFallbackReason = "Session v2 вернул пустой список треков"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                lastFallbackReason = "Session v2 ошибка: \(error.localizedDescription)"
                print("[RotorService] Level 1 Session v2 start error: \(error)")
            }

            guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

            // Level 2: Rotor Session v2 with Simplified Seeds
            let simplifiedSeeds = buildSimplifiedSeeds(for: context, vibe: activeVibe, excluding: effectiveSeeds)
            if !simplifiedSeeds.isEmpty && simplifiedSeeds != effectiveSeeds {
                do {
                    let retryPayload = YMRotorSessionNewRequest(seeds: simplifiedSeeds)
                    let retryBody = try encoder.encode(retryPayload)

                    let result: YMRotorStationTracksResult = try await networkClient.request(
                        endpoint: "/rotor/session/new",
                        method: "POST",
                        body: retryBody,
                        headers: ["Content-Type": "application/json"],
                        cachePolicy: .reloadIgnoringLocalCacheData
                    )

                    guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

                    recordTrackInsights(from: result.sequence)
                    let rawTracks = result.sequence.compactMap(\.track)
                    let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
                    let uniqueTracks = filterExcludedTracks(dedupedTracks)
                    if !uniqueTracks.isEmpty {
                        self.currentSessionId = result.radioSessionId
                        self.currentBatchId = result.batchId
                        self.isUsingV1Protocol = false
                        self.activeV1StationId = nil
                        updateDiagnostics(
                            activeProtocol: "Rotor Session v2 (Simplified Seeds)",
                            isFallbackActive: true,
                            activeLevel: 2,
                            activeSeeds: simplifiedSeeds,
                            fetchedDelta: uniqueTracks.count,
                            duplicatesDelta: duplicatesFiltered,
                            lastFallbackReason: lastFallbackReason
                        )

                        try? await sendFeedback(type: .radioStarted, trackId: nil)
                        return uniqueTracks
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    lastFallbackReason = "Session v2 Simplified ошибка: \(error.localizedDescription)"
                    print("[RotorService] Level 2 Session v2 simplified retry failed: \(error)")
                }
            }

            guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

            // If user strictly locked mode to v2Only, do not fall back to v1
            if preferredAPIMode == .v2Only {
                updateDiagnostics(
                    activeProtocol: "Ошибка Rotor Session v2",
                    isFallbackActive: true,
                    activeLevel: 0,
                    activeSeeds: effectiveSeeds,
                    fetchedDelta: 0,
                    duplicatesDelta: 0,
                    lastFallbackReason: lastFallbackReason
                )
                throw lastError ?? YMAPIError.emptyResult
            }
        } else {
            lastFallbackReason = "Выбран ручной режим Rotor Radio v1"
        }

        // Level 3: Rotor Station v1 (GET /rotor/station/{targetStation}/tracks?settings2=true)
        let targetStation = context.fallbackStationId
        if let v1Settings = activeVibe.v1SettingsPayload {
            try? await applyV1Settings(stationId: targetStation, settings: v1Settings)
        }

        guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

        let v1QueryItems = [URLQueryItem(name: "settings2", value: "true")]

        var response: YMRotorStationTracksResult?
        var usedBaseWaveFallback = false

        do {
            response = try await networkClient.request(
                endpoint: "/rotor/station/\(YMNetworkClient.escapePath(targetStation))/tracks",
                queryItems: v1QueryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
            self.isUsingV1Protocol = true
            self.activeV1StationId = targetStation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[RotorService] Level 3 Rotor v1 station \(targetStation) failed: \(error). Falling back to user:onyourwave...")
            lastFallbackReason = "Station v1 (\(targetStation)): \(error.localizedDescription)"

            guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

            // Level 4: Base Wave Fallback (GET /rotor/station/user:onyourwave/tracks?settings2=true)
            if targetStation != "user:onyourwave" {
                usedBaseWaveFallback = true
                if let v1Settings = activeVibe.v1SettingsPayload {
                    try? await applyV1Settings(stationId: "user:onyourwave", settings: v1Settings)
                }
                guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                response = try await networkClient.request(
                    endpoint: "/rotor/station/user:onyourwave/tracks",
                    queryItems: v1QueryItems,
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
                guard gen == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                self.isUsingV1Protocol = true
                self.activeV1StationId = "user:onyourwave"
            } else {
                updateDiagnostics(
                    activeProtocol: "Ошибка Rotor Station v1",
                    isFallbackActive: true,
                    activeLevel: 0,
                    activeSeeds: [targetStation],
                    fetchedDelta: 0,
                    duplicatesDelta: 0,
                    lastFallbackReason: lastFallbackReason
                )
                throw error
            }
        }

        guard let validResponse = response else {
            return []
        }

        self.currentSessionId = validResponse.radioSessionId
        self.currentBatchId = validResponse.batchId
        recordTrackInsights(from: validResponse.sequence)
        let rawTracks = validResponse.sequence.compactMap(\.track)
        let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
        let uniqueTracks = filterExcludedTracks(dedupedTracks)

        let protocolLabel = usedBaseWaveFallback
            ? "Base Wave Fallback (GET /rotor/station/user:onyourwave/tracks)"
            : "Rotor Station v1 (GET /rotor/station/\(targetStation)/tracks)"

        updateDiagnostics(
            activeProtocol: protocolLabel,
            isFallbackActive: true,
            activeLevel: usedBaseWaveFallback ? 4 : 3,
            activeSeeds: usedBaseWaveFallback ? ["user:onyourwave"] : [targetStation],
            fetchedDelta: uniqueTracks.count,
            duplicatesDelta: duplicatesFiltered,
            lastFallbackReason: lastFallbackReason
        )

        try? await sendFeedback(type: .radioStarted, trackId: nil)

        return uniqueTracks
    }

    /// Fetches next batch of tracks using v2 if radioSessionId is present and v2 is active, otherwise v1.
    /// Passes queue identifiers and handles transparent session recreation upon unknown-session or terminated.
    public func fetchNextBatch(lastTrackId: String, queueHistory: [String] = []) async throws -> [YMTrack] {
        let gen = sessionGeneration
        var queueList: [String] = []
        if !queueHistory.isEmpty {
            queueList = Array(queueHistory.suffix(25))
        } else if !recentQueueIdentifiers.isEmpty {
            queueList = Array(recentQueueIdentifiers.suffix(25))
        } else {
            queueList = [lastTrackId]
        }

        var fallbackReason: String? = diagnostics.lastFallbackReason

        // Try Rotor Session v2 if sessionId is active, we're not currently on v1, and mode permits v2
        if !isUsingV1Protocol, preferredAPIMode != .v1Fallback, let sessionId = currentSessionId {
            do {
                let payload = YMRotorSessionNextTracksRequest(queue: queueList)
                let body = try encoder.encode(payload)

                let result: YMRotorStationTracksResult = try await networkClient.request(
                    endpoint: "/rotor/session/\(YMNetworkClient.escapePath(sessionId))/tracks",
                    method: "POST",
                    body: body,
                    headers: ["Content-Type": "application/json"],
                    cachePolicy: .reloadIgnoringLocalCacheData
                )

                guard gen == sessionGeneration, !Task.isCancelled else { return [] }

                // Check if session is expired or terminated -> transparently recreate v2 session
                if result.unknownSession == true || result.terminated == true {
                    print("[RotorService] Session unknown/terminated, transparently recreating v2 session...")
                    let seedsToUse = diagnostics.activeSeeds.isEmpty ? activeContext.seeds : diagnostics.activeSeeds
                    let newReq = YMRotorSessionNewRequest(seeds: seedsToUse, queue: queueList)
                    let newBody = try encoder.encode(newReq)

                    let recreatedResult: YMRotorStationTracksResult = try await networkClient.request(
                        endpoint: "/rotor/session/new",
                        method: "POST",
                        body: newBody,
                        headers: ["Content-Type": "application/json"],
                        cachePolicy: .reloadIgnoringLocalCacheData
                    )

                    guard gen == sessionGeneration, !Task.isCancelled else { return [] }

                    if let newSessionId = recreatedResult.radioSessionId {
                        self.currentSessionId = newSessionId
                    }
                    if let newBatchId = recreatedResult.batchId {
                        self.currentBatchId = newBatchId
                    }
                    recordTrackInsights(from: recreatedResult.sequence)
                    let rawTracks = recreatedResult.sequence.compactMap(\.track)
                    let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
                    let uniqueTracks = filterExcludedTracks(dedupedTracks)
                    if !uniqueTracks.isEmpty {
                        updateDiagnostics(
                            activeProtocol: diagnostics.activeProtocol,
                            isFallbackActive: diagnostics.isFallbackActive,
                            activeLevel: diagnostics.activeLevel,
                            activeSeeds: diagnostics.activeSeeds,
                            fetchedDelta: uniqueTracks.count,
                            duplicatesDelta: duplicatesFiltered,
                            lastFallbackReason: diagnostics.lastFallbackReason
                        )
                        return uniqueTracks
                    }
                } else {
                    if let newBatchId = result.batchId {
                        self.currentBatchId = newBatchId
                    }
                    recordTrackInsights(from: result.sequence)
                    let rawTracks = result.sequence.compactMap(\.track)
                    let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
                    let uniqueTracks = filterExcludedTracks(dedupedTracks)
                    if !uniqueTracks.isEmpty {
                        updateDiagnostics(
                            activeProtocol: diagnostics.activeLevel == 2
                                ? "Rotor Session v2 (Simplified Seeds)"
                                : "Rotor Session v2 (POST /rotor/session/new)",
                            isFallbackActive: diagnostics.activeLevel == 2,
                            activeLevel: diagnostics.activeLevel == 2 ? 2 : 1,
                            activeSeeds: diagnostics.activeSeeds,
                            fetchedDelta: uniqueTracks.count,
                            duplicatesDelta: duplicatesFiltered,
                            lastFallbackReason: diagnostics.lastFallbackReason
                        )
                        return uniqueTracks
                    }
                }
            } catch is CancellationError {
                return []
            } catch {
                fallbackReason = "Session v2 next batch ошибка: \(error.localizedDescription)"
                print("[RotorService] Session v2 next batch error: \(error). Falling back to v1...")
                if preferredAPIMode == .v2Only {
                    throw error
                }
            }
        }

        guard gen == sessionGeneration, !Task.isCancelled else { return [] }

        // Fallback to Rotor v1: GET /rotor/station/\(stationId)/tracks
        let stationId = activeV1StationId ?? activeContext.fallbackStationId
        let lastId = queueList.last ?? lastTrackId
        let queryItems = [
            URLQueryItem(name: "settings2", value: "true"),
            URLQueryItem(name: "queue", value: lastId)
        ]

        var response: YMRotorStationTracksResult?
        var usedBaseWaveFallback = false
        do {
            response = try await networkClient.request(
                endpoint: "/rotor/station/\(YMNetworkClient.escapePath(stationId))/tracks",
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
            guard gen == sessionGeneration, !Task.isCancelled else { return [] }
            self.isUsingV1Protocol = true
            self.activeV1StationId = stationId
        } catch is CancellationError {
            return []
        } catch {
            fallbackReason = "Station v1 (\(stationId)): \(error.localizedDescription)"
            guard gen == sessionGeneration, !Task.isCancelled else { return [] }
            if stationId != "user:onyourwave" {
                usedBaseWaveFallback = true
                response = try await networkClient.request(
                    endpoint: "/rotor/station/user:onyourwave/tracks",
                    queryItems: queryItems,
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
                guard gen == sessionGeneration, !Task.isCancelled else { return [] }
                self.isUsingV1Protocol = true
                self.activeV1StationId = "user:onyourwave"
            } else {
                throw error
            }
        }

        if let newBatchId = response?.batchId {
            self.currentBatchId = newBatchId
        }

        let sequence = response?.sequence ?? []
        recordTrackInsights(from: sequence)
        let rawTracks = sequence.compactMap(\.track)
        let (dedupedTracks, duplicatesFiltered) = filterUniqueTracksWithStats(rawTracks)
        let uniqueTracks = filterExcludedTracks(dedupedTracks)

        let finalStationId = activeV1StationId ?? (usedBaseWaveFallback ? "user:onyourwave" : stationId)
        updateDiagnostics(
            activeProtocol: usedBaseWaveFallback
                ? "Base Wave Fallback (GET /rotor/station/user:onyourwave/tracks)"
                : "Rotor Station v1 (GET /rotor/station/\(finalStationId)/tracks)",
            isFallbackActive: true,
            activeLevel: usedBaseWaveFallback ? 4 : 3,
            activeSeeds: [finalStationId],
            fetchedDelta: uniqueTracks.count,
            duplicatesDelta: duplicatesFiltered,
            lastFallbackReason: fallbackReason
        )

        return uniqueTracks
    }

    // MARK: - Helpers

    private struct YMRotorV1SettingsRequest: Codable {
        let moodEnergy: String
        let diversity: String
        let language: String
        let type: String
    }

    private func applyV1Settings(
        stationId: String,
        settings: (moodEnergy: String, diversity: String, language: String)
    ) async throws {
        let req = YMRotorV1SettingsRequest(
            moodEnergy: settings.moodEnergy,
            diversity: settings.diversity,
            language: settings.language,
            type: "rotor"
        )
        let body = try encoder.encode(req)
        let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
            endpoint: "/rotor/station/\(YMNetworkClient.escapePath(stationId))/settings3",
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json"]
        )
    }

    private func buildSimplifiedSeeds(
        for context: YMWaveContext,
        vibe: YMWaveVibePreset,
        excluding effectiveSeeds: [String]
    ) -> [String] {
        let vibeSeed = vibe.seedParameter

        // 1. Saved wave or playlist with fallback track seeds: try pure track seeds (+ optional vibe)
        if !context.fallbackTrackSeeds.isEmpty {
            var seeds = context.fallbackTrackSeeds
            if let vibeSeed {
                seeds.append(vibeSeed)
            }
            if seeds != effectiveSeeds {
                return seeds
            }
            if vibeSeed != nil {
                return context.fallbackTrackSeeds
            }
        }

        // 2. If station/artist has vibe seed (count > 1), try context.seeds without vibe
        if vibeSeed != nil, !context.seeds.isEmpty {
            if context != .myWaveDefault {
                return context.seeds
            } else {
                return ["user:onyourwave"]
            }
        }

        return []
    }

    private func filterExcludedTracks(_ tracks: [YMTrack]) -> [YMTrack] {
        guard !activeExcludedTrackIds.isEmpty, !tracks.isEmpty else { return tracks }
        let filtered = tracks.filter { track in
            let cleanId = track.id.components(separatedBy: ":").first ?? track.id
            return !activeExcludedTrackIds.contains(cleanId) && !activeExcludedTrackIds.contains(track.id)
        }
        return filtered.isEmpty ? tracks : filtered
    }

    private func filterUniqueTracksWithStats(_ tracks: [YMTrack]) -> (unique: [YMTrack], duplicatesFiltered: Int) {
        var result: [YMTrack] = []
        var duplicates = 0
        for track in tracks {
            let cleanId = track.id.components(separatedBy: ":").first ?? track.id
            if !seenTrackIds.contains(cleanId) && !seenTrackIds.contains(track.id) {
                seenTrackIds.insert(cleanId)
                seenTrackIdList.append(cleanId)
                if track.id != cleanId {
                    seenTrackIds.insert(track.id)
                    seenTrackIdList.append(track.id)
                }
                recentQueueIdentifiers.append(track.rotorTrackIdentifier)
                result.append(track)
            } else {
                duplicates += 1
            }
        }
        if seenTrackIdList.count > 500 {
            let overflow = seenTrackIdList.count - 500
            for id in seenTrackIdList.prefix(overflow) {
                seenTrackIds.remove(id)
            }
            seenTrackIdList.removeFirst(overflow)
        }
        if recentQueueIdentifiers.count > 100 {
            recentQueueIdentifiers.removeFirst(recentQueueIdentifiers.count - 100)
        }
        return (result, duplicates)
    }

    private func recordTrackInsights(from sequence: [YMRotorSequenceItem]) {
        var collected: [(trackId: String, insight: YMRotorTrackInsight)] = []
        for item in sequence {
            guard let track = item.track else { continue }
            let insight = YMRotorTrackInsight(
                trackParameters: item.trackParameters,
                description: item.description,
                waveText: item.waveText
            )
            if insight.formattedInsight != nil {
                collected.append((track.id, insight))
            }
        }
        guard !collected.isEmpty else { return }
        let itemsToRecord = collected
        Task { @MainActor in
            RotorDiagnosticsStore.shared.recordTrackInsights(itemsToRecord)
        }
    }

    private func updateDiagnostics(
        activeProtocol: String,
        isFallbackActive: Bool,
        activeLevel: Int,
        activeSeeds: [String],
        fetchedDelta: Int,
        duplicatesDelta: Int,
        lastFallbackReason: String?
    ) {
        diagnostics = YMRotorDiagnostics(
            activeProtocol: activeProtocol,
            isFallbackActive: isFallbackActive,
            activeLevel: activeLevel,
            sessionId: currentSessionId,
            batchId: currentBatchId,
            activeSeeds: activeSeeds,
            fetchedTracksCount: diagnostics.fetchedTracksCount + fetchedDelta,
            filteredDuplicatesCount: diagnostics.filteredDuplicatesCount + duplicatesDelta,
            lastFallbackReason: lastFallbackReason,
            lastUpdated: Date()
        )
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        let snapshot = diagnostics
        Task { @MainActor in
            RotorDiagnosticsStore.shared.updateDiagnostics(snapshot)
        }
    }

    // MARK: - Telemetry Feedback

    public func sendRadioStarted(initialTrack: YMTrack? = nil) async throws {
        try await sendFeedback(type: .radioStarted, trackId: nil)
    }

    public func sendTrackStarted(track: YMTrack) async throws {
        try await sendFeedback(type: .trackStarted, trackId: track.rotorTrackIdentifier)
    }

    public func sendTrackFinished(track: YMTrack, totalPlayedSeconds: Double) async throws {
        try await sendFeedback(type: .trackFinished, trackId: track.rotorTrackIdentifier, totalPlayedSeconds: totalPlayedSeconds)
    }

    public func sendTrackSkipped(track: YMTrack, playedSeconds: Double) async throws {
        try await sendFeedback(type: .skip, trackId: track.rotorTrackIdentifier, totalPlayedSeconds: playedSeconds)
    }

    /// Сигнал "Больше похожих треков": отправляет алгоритму радио событие like,
    /// не отправляя ложный trackFinished до завершения трека.
    public func sendAlgorithmicMoreLikeThis(track: YMTrack) async throws {
        try await sendFeedback(type: .like, trackId: track.rotorTrackIdentifier)
    }

    /// Сигнал "Меньше таких треков": отправляет алгоритму радио события dislike + skip с минимальным временем.
    public func sendAlgorithmicLessLikeThis(track: YMTrack, playedSeconds: Double) async throws {
        try? await sendFeedback(type: .dislike, trackId: track.rotorTrackIdentifier)
        try await sendFeedback(type: .skip, trackId: track.rotorTrackIdentifier, totalPlayedSeconds: min(playedSeconds, 2.0))
    }

    private func sendFeedback(
        type: YMRotorEventType,
        trackId: String? = nil,
        totalPlayedSeconds: Double? = nil
    ) async throws {
        let fromValue = activeContext.idForFrom
            ?? "mobile-home-rup_main-\(activeContext.seeds.first?.replacingOccurrences(of: ":", with: "-") ?? "user-onyourwave")-default"
        let validSeconds: Double? = (totalPlayedSeconds != nil && totalPlayedSeconds! > 0) ? totalPlayedSeconds : nil
        let timestamp = isoFormatter.string(from: Date())

        if !isUsingV1Protocol, preferredAPIMode != .v1Fallback, let sessionId = currentSessionId {
            // Rotor Session v2 feedback: POST /rotor/session/{radioSessionId}/feedback
            let event = YMRotorSessionEvent(
                type: type,
                timestamp: timestamp,
                trackId: trackId,
                totalPlayedSeconds: validSeconds
            )
            let v2Payload = YMRotorSessionFeedbackRequest(
                event: event,
                batchId: currentBatchId,
                from: type == .radioStarted ? fromValue : nil
            )
            let body = try encoder.encode(v2Payload)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/rotor/session/\(YMNetworkClient.escapePath(sessionId))/feedback",
                method: "POST",
                body: body,
                headers: ["Content-Type": "application/json"]
            )
            return
        }

        // Rotor v1 flat feedback: POST /rotor/station/\(stationId)/feedback?batch-id={batchId}
        let stationId = activeV1StationId ?? activeContext.fallbackStationId
        guard let batchId = currentBatchId else {
            print("[RotorService] Skipping v1 feedback \(type): batchId is nil")
            return
        }

        let payload = YMRotorStationFeedbackRequest(
            type: type,
            timestamp: timestamp,
            trackId: trackId,
            totalPlayedSeconds: validSeconds,
            from: type == .radioStarted ? fromValue : nil
        )
        let body = try encoder.encode(payload)
        let queryItems = [
            URLQueryItem(name: "batch-id", value: batchId)
        ]

        let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
            endpoint: "/rotor/station/\(YMNetworkClient.escapePath(stationId))/feedback",
            method: "POST",
            queryItems: queryItems,
            body: body,
            headers: ["Content-Type": "application/json"]
        )
    }
}
