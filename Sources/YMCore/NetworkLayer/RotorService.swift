import Foundation

/// Rotor Station ("Моя волна") Service actor.
/// Supports Rotor Session v2 (POST /rotor/session/new, /tracks, /feedback) with automatic fallback to Rotor v1.
/// Manages batch fetching, queue pagination, strict deduplication, session history, wave vibes,
/// context presets, and telemetry sequence: radioStarted -> trackStarted -> trackFinished / skip / like / dislike.
public actor RotorService {
    public static let shared = RotorService()

    private let networkClient: YMNetworkClient
    private var currentSessionId: String?
    private var currentBatchId: String?
    private var seenTrackIds: Set<String> = []
    private var seenTrackIdList: [String] = []
    private var recentQueueIdentifiers: [String] = []
    private let isoFormatter: ISO8601DateFormatter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var activeContext: YMWaveContext = .myWaveDefault
    private var activeVibe: YMWaveVibePreset = .defaultWave

    public init(networkClient: YMNetworkClient = .shared) {
        self.networkClient = networkClient
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = formatter
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
        self.currentSessionId = nil
        self.currentBatchId = nil
        self.seenTrackIds.removeAll()
        self.seenTrackIdList.removeAll()
        self.recentQueueIdentifiers.removeAll()
    }

    // MARK: - Station Loading

    /// Starts "Моя волна" station using Rotor Session v2 with fallback to v1.
    /// Resets duplicate tracking and session history.
    public func startWave(
        context: YMWaveContext = .myWaveDefault,
        vibe: YMWaveVibePreset? = nil
    ) async throws -> [YMTrack] {
        resetSession()
        self.activeContext = context
        self.activeVibe = vibe ?? .defaultWave

        var effectiveSeeds = context.seeds
        if let vibeSeed = activeVibe.seedParameter {
            effectiveSeeds.append(vibeSeed)
        }

        // 1. Try Rotor Session v2: POST /rotor/session/new
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

            let rawTracks = result.sequence.compactMap(\.track)
            let uniqueTracks = filterUniqueTracks(rawTracks)
            if !uniqueTracks.isEmpty {
                self.currentSessionId = result.radioSessionId
                self.currentBatchId = result.batchId

                try? await sendFeedback(type: .radioStarted, trackId: nil)
                return uniqueTracks
            }
        } catch {
            print("[RotorService] Session v2 start error: \(error).")

            // Retry v2 with track-only seeds if combined seeds failed and count > 1
            var trackSeeds = context.seeds.filter { $0.hasPrefix("track:") }
            if context.seeds.count > 1 && !trackSeeds.isEmpty {
                if let vibeSeed = activeVibe.seedParameter {
                    trackSeeds.append(vibeSeed)
                }
                do {
                    let retryPayload = YMRotorSessionNewRequest(seeds: trackSeeds)
                    let retryBody = try encoder.encode(retryPayload)

                    let result: YMRotorStationTracksResult = try await networkClient.request(
                        endpoint: "/rotor/session/new",
                        method: "POST",
                        body: retryBody,
                        headers: ["Content-Type": "application/json"],
                        cachePolicy: .reloadIgnoringLocalCacheData
                    )

                    let rawTracks = result.sequence.compactMap(\.track)
                    let uniqueTracks = filterUniqueTracks(rawTracks)
                    if !uniqueTracks.isEmpty {
                        self.currentSessionId = result.radioSessionId
                        self.currentBatchId = result.batchId

                        try? await sendFeedback(type: .radioStarted, trackId: nil)
                        return uniqueTracks
                    }
                } catch {
                    print("[RotorService] Session v2 track-only retry failed: \(error)")
                }
            }
        }

        // 2. Fallback to Rotor v1: GET /rotor/station/\(context.fallbackStationId)/tracks?settings2=true
        let queryItems = [
            URLQueryItem(name: "settings2", value: "true")
        ]

        var response: YMRotorStationTracksResult?
        do {
            response = try await networkClient.request(
                endpoint: "/rotor/station/\(YMNetworkClient.escapePath(context.fallbackStationId))/tracks",
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } catch {
            print("[RotorService] Rotor v1 station \(context.fallbackStationId) failed: \(error). Falling back to user:onyourwave...")
            if context.fallbackStationId != "user:onyourwave" {
                response = try await networkClient.request(
                    endpoint: "/rotor/station/user:onyourwave/tracks",
                    queryItems: queryItems,
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
            } else {
                throw error
            }
        }

        guard let validResponse = response else {
            return []
        }

        self.currentSessionId = validResponse.radioSessionId
        self.currentBatchId = validResponse.batchId
        let rawTracks = validResponse.sequence.compactMap(\.track)
        let uniqueTracks = filterUniqueTracks(rawTracks)

        try? await sendFeedback(type: .radioStarted, trackId: nil)

        return uniqueTracks
    }

    /// Fetches next batch of tracks using v2 if radioSessionId is present, otherwise v1.
    /// Passes up to 25 recent track identifiers to the API and filters out any duplicates heard in the current session.
    public func fetchNextBatch(lastTrackId: String, queueHistory: [String] = []) async throws -> [YMTrack] {
        var queueList: [String] = []
        if !queueHistory.isEmpty {
            queueList = Array(queueHistory.suffix(25))
        } else if !recentQueueIdentifiers.isEmpty {
            queueList = Array(recentQueueIdentifiers.suffix(25))
        } else {
            queueList = [lastTrackId]
        }

        // Try Rotor Session v2 if sessionId is active
        if let sessionId = currentSessionId {
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

                if let newBatchId = result.batchId {
                    self.currentBatchId = newBatchId
                }
                let rawTracks = result.sequence.compactMap(\.track)
                let uniqueTracks = filterUniqueTracks(rawTracks)
                if !uniqueTracks.isEmpty {
                    return uniqueTracks
                }
            } catch {
                print("[RotorService] Session v2 next batch error: \(error). Falling back to v1...")
            }
        }

        // Fallback to Rotor v1: GET /rotor/station/\(activeContext.fallbackStationId)/tracks
        let queueParam = queueList.joined(separator: ",")
        let queryItems = [
            URLQueryItem(name: "settings2", value: "true"),
            URLQueryItem(name: "queue", value: queueParam)
        ]

        var response: YMRotorStationTracksResult?
        do {
            response = try await networkClient.request(
                endpoint: "/rotor/station/\(YMNetworkClient.escapePath(activeContext.fallbackStationId))/tracks",
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } catch {
            if activeContext.fallbackStationId != "user:onyourwave" {
                response = try await networkClient.request(
                    endpoint: "/rotor/station/user:onyourwave/tracks",
                    queryItems: queryItems,
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
            } else {
                throw error
            }
        }

        if let newBatchId = response?.batchId {
            self.currentBatchId = newBatchId
        }

        let rawTracks = response?.sequence.compactMap(\.track) ?? []
        return filterUniqueTracks(rawTracks)
    }

    private func filterUniqueTracks(_ tracks: [YMTrack]) -> [YMTrack] {
        var result: [YMTrack] = []
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
        return result
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

    /// Сигнал "Больше похожих треков": отправляет алгоритму радио события like + trackFinished (100% прослушивание),
    /// не добавляя трек в библиотеку "Мне нравится" пользователя.
    public func sendAlgorithmicMoreLikeThis(track: YMTrack) async throws {
        let fullDuration = Double(track.durationMs ?? 180_000) / 1000.0
        try? await sendFeedback(type: .like, trackId: track.rotorTrackIdentifier)
        try await sendFeedback(type: .trackFinished, trackId: track.rotorTrackIdentifier, totalPlayedSeconds: max(120.0, fullDuration))
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
        let fromValue = "mobile-home-rup_main-\(activeContext.seeds.first?.replacingOccurrences(of: ":", with: "-") ?? "user-onyourwave")-default"
        let event = YMRotorFeedbackEvent(
            type: type,
            timestamp: isoFormatter.string(from: Date()),
            trackId: trackId,
            totalPlayedSeconds: totalPlayedSeconds,
            from: fromValue
        )

        if let sessionId = currentSessionId {
            // Rotor Session v2 feedback: POST /rotor/session/{radioSessionId}/feedback
            let v2Payload = YMRotorSessionFeedbackRequest(event: event, batchId: currentBatchId)
            let body = try encoder.encode(v2Payload)
            let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
                endpoint: "/rotor/session/\(YMNetworkClient.escapePath(sessionId))/feedback",
                method: "POST",
                body: body,
                headers: ["Content-Type": "application/json"]
            )
            return
        }

        // Rotor v1 feedback: POST /rotor/station/\(activeContext.fallbackStationId)/feedback?batch-id={batchId}
        guard let batchId = currentBatchId else {
            print("[RotorService] Skipping v1 feedback \(type): batchId is nil")
            return
        }

        let payload = YMRotorFeedbackPayload(event: event)
        let body = try encoder.encode(payload)
        let queryItems = [
            URLQueryItem(name: "batch-id", value: batchId)
        ]

        let _: (Data, HTTPURLResponse) = try await networkClient.performRawRequest(
            endpoint: "/rotor/station/\(YMNetworkClient.escapePath(activeContext.fallbackStationId))/feedback",
            method: "POST",
            queryItems: queryItems,
            body: body,
            headers: ["Content-Type": "application/json"]
        )
    }
}
