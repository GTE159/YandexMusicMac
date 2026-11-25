import Foundation
import Observation

/// Candidate snapshot generated from the current in-memory wave session before user confirmation in UI.
public struct WaveSnapshotCandidate: Sendable, Equatable {
    public let baseContextSeeds: [String]
    public let baseContextTitle: String
    public let baseFallbackStationId: String
    public let vibe: YMWaveVibePreset
    public let anchorTracks: [SavedWaveAnchorTrack]
    public let excludedTrackIds: [String]

    public var hasNonDefaultContext: Bool {
        baseContextSeeds.contains { seed in
            !seed.isEmpty && seed != "user:onyourwave" && !seed.hasPrefix("track:")
        }
    }

    public init(
        baseContextSeeds: [String],
        baseContextTitle: String,
        baseFallbackStationId: String,
        vibe: YMWaveVibePreset,
        anchorTracks: [SavedWaveAnchorTrack],
        excludedTrackIds: [String]
    ) {
        self.baseContextSeeds = baseContextSeeds
        self.baseContextTitle = baseContextTitle
        self.baseFallbackStationId = baseFallbackStationId
        self.vibe = vibe
        self.anchorTracks = anchorTracks
        self.excludedTrackIds = excludedTrackIds
    }
}

/// Ephemeral in-memory tracker computing the musical DNA of the active wave session
/// and detecting style drift (`hasPendingStyleDrift`) when playing a saved wave preset.
/// Never mutates persisted `SavedWavePreset` instances automatically.
@Observable
@MainActor
public final class WaveSessionTasteTracker {
    private struct TrackSignal {
        var anchor: SavedWaveAnchorTrack
        var score: Double
        var lastTouchedAt: Date
        var touchSequence: UInt64
        var isHardExcluded: Bool
        var isQuickSkipped: Bool
        var isFromBaselinePreset: Bool
    }

    public private(set) var hasPendingStyleDrift: Bool = false
    public private(set) var baselinePreset: SavedWavePreset? = nil
    public private(set) var currentBaseContext: YMWaveContext = .myWaveDefault
    public private(set) var currentVibe: YMWaveVibePreset = .defaultWave

    public var currentExcludedTrackIds: [String] {
        excludedIdsOrder
    }

    @ObservationIgnored private var signals: [String: TrackSignal] = [:]
    @ObservationIgnored private var excludedIdsOrder: [String] = []
    @ObservationIgnored private var baselineAnchorIds: Set<String> = []
    @ObservationIgnored private var newPositiveTrackIds: Set<String> = []
    @ObservationIgnored private var consecutiveQuickSkips: Int = 0
    @ObservationIgnored private var touchCounter: UInt64 = 0

    @ObservationIgnored private var cleanBaseSeeds: [String] = ["user:onyourwave"]
    @ObservationIgnored private var cleanBaseTitle: String = "Моя волна"
    @ObservationIgnored private var cleanBaseFallbackStationId: String = "user:onyourwave"

    public init() {}

    // MARK: - Session Lifecycle

    public func beginFreshSession(context: YMWaveContext, vibe: YMWaveVibePreset) {
        signals.removeAll()
        excludedIdsOrder.removeAll()
        baselineAnchorIds.removeAll()
        newPositiveTrackIds.removeAll()
        consecutiveQuickSkips = 0
        touchCounter = 0

        baselinePreset = nil
        hasPendingStyleDrift = false
        currentBaseContext = context
        currentVibe = vibe

        let sanitizedSeeds = Self.extractCleanBaseSeeds(from: context.seeds)
        cleanBaseSeeds = sanitizedSeeds
        cleanBaseTitle = context.title
        cleanBaseFallbackStationId = context.fallbackStationId
    }

    public func beginSessionFromPreset(_ preset: SavedWavePreset, context: YMWaveContext) {
        signals.removeAll()
        newPositiveTrackIds.removeAll()
        consecutiveQuickSkips = 0
        touchCounter = 0

        baselinePreset = preset
        hasPendingStyleDrift = false
        currentBaseContext = context
        currentVibe = preset.vibe

        cleanBaseSeeds = Self.extractCleanBaseSeeds(from: preset.baseContextSeeds)
        cleanBaseTitle = preset.baseContextTitle
        cleanBaseFallbackStationId = preset.baseFallbackStationId

        baselineAnchorIds = Set(preset.anchorTracks.map(\.id))
        excludedIdsOrder = Array(preset.excludedTrackIds.prefix(30))

        let now = Date()
        for anchor in preset.anchorTracks {
            touchCounter &+= 1
            signals[anchor.id] = TrackSignal(
                anchor: anchor,
                score: 1.5,
                lastTouchedAt: now,
                touchSequence: touchCounter,
                isHardExcluded: false,
                isQuickSkipped: false,
                isFromBaselinePreset: true
            )
        }
    }

    public func detachBaselinePreset() {
        baselinePreset = nil
        baselineAnchorIds.removeAll()
        newPositiveTrackIds.removeAll()
        consecutiveQuickSkips = 0
        hasPendingStyleDrift = false
    }

    // MARK: - Event Recording

    public func recordVibeChange(_ newVibe: YMWaveVibePreset) {
        currentVibe = newVibe
        if let base = baselinePreset {
            hasPendingStyleDrift = hasPendingStyleDrift || (newVibe != base.vibe)
        }
    }

    public func recordOutcome(_ outcome: YMWaveTrackOutcome, for track: YMTrack) {
        guard !track.isPlaceholder, !track.isSpacer else { return }
        let cleanId = Self.cleanTrackId(from: track.id)
        let now = Date()
        touchCounter &+= 1
        let seq = touchCounter

        switch outcome {
        case .started:
            if var existing = signals[cleanId] {
                existing.lastTouchedAt = now
                existing.touchSequence = seq
                if existing.anchor.coverUri == nil, track.effectiveCoverUri != nil {
                    existing.anchor = SavedWaveAnchorTrack(from: track)
                }
                signals[cleanId] = existing
            } else {
                signals[cleanId] = TrackSignal(
                    anchor: SavedWaveAnchorTrack(from: track),
                    score: 0.8,
                    lastTouchedAt: now,
                    touchSequence: seq,
                    isHardExcluded: excludedIdsOrder.contains(cleanId),
                    isQuickSkipped: false,
                    isFromBaselinePreset: false
                )
            }

        case .finished(let playedSeconds):
            consecutiveQuickSkips = 0
            let durationSec = Double(track.durationMs ?? 0) / 1000.0
            let isSubstantial = playedSeconds >= 30.0 || (durationSec > 0 && playedSeconds >= durationSec * 0.5)
            let delta = isSubstantial ? 3.0 : 1.5

            if var existing = signals[cleanId] {
                existing.score = Self.clamped(existing.score + delta)
                existing.lastTouchedAt = now
                existing.touchSequence = seq
                existing.isQuickSkipped = false
                signals[cleanId] = existing
            } else {
                signals[cleanId] = TrackSignal(
                    anchor: SavedWaveAnchorTrack(from: track),
                    score: Self.clamped(delta),
                    lastTouchedAt: now,
                    touchSequence: seq,
                    isHardExcluded: false,
                    isQuickSkipped: false,
                    isFromBaselinePreset: false
                )
            }

            if baselinePreset != nil && !baselineAnchorIds.contains(cleanId) {
                newPositiveTrackIds.insert(cleanId)
                if newPositiveTrackIds.count >= 2 {
                    hasPendingStyleDrift = true
                }
            }

        case .skipped(let playedSeconds):
            if playedSeconds < 15.0 {
                if var existing = signals[cleanId] {
                    existing.score = Self.clamped(existing.score - 3.0)
                    existing.lastTouchedAt = now
                    existing.touchSequence = seq
                    existing.isQuickSkipped = true
                    signals[cleanId] = existing
                } else {
                    signals[cleanId] = TrackSignal(
                        anchor: SavedWaveAnchorTrack(from: track),
                        score: -3.0,
                        lastTouchedAt: now,
                        touchSequence: seq,
                        isHardExcluded: false,
                        isQuickSkipped: true,
                        isFromBaselinePreset: false
                    )
                }
                consecutiveQuickSkips += 1
                if baselinePreset != nil && consecutiveQuickSkips >= 2 {
                    hasPendingStyleDrift = true
                }
            } else if playedSeconds >= 45.0 {
                consecutiveQuickSkips = 0
                if var existing = signals[cleanId] {
                    existing.score = Self.clamped(existing.score + 2.0)
                    existing.lastTouchedAt = now
                    existing.touchSequence = seq
                    existing.isQuickSkipped = false
                    signals[cleanId] = existing
                } else {
                    signals[cleanId] = TrackSignal(
                        anchor: SavedWaveAnchorTrack(from: track),
                        score: 2.0,
                        lastTouchedAt: now,
                        touchSequence: seq,
                        isHardExcluded: false,
                        isQuickSkipped: false,
                        isFromBaselinePreset: false
                    )
                }
                if baselinePreset != nil && !baselineAnchorIds.contains(cleanId) {
                    newPositiveTrackIds.insert(cleanId)
                    if newPositiveTrackIds.count >= 2 {
                        hasPendingStyleDrift = true
                    }
                }
            } else {
                consecutiveQuickSkips = 0
            }

        case .liked:
            recordPositiveSignalBoost(for: track, delta: 4.5, markDrift: true, at: now, seq: seq)

        case .moreLikeThis, .addedToWaveAsLiked:
            recordPositiveSignalBoost(for: track, delta: 5.5, markDrift: true, at: now, seq: seq)

        case .lessLikeThis:
            consecutiveQuickSkips = 0
            newPositiveTrackIds.remove(cleanId)
            if var existing = signals[cleanId] {
                existing.score = Self.clamped(existing.score - 10.0)
                existing.isHardExcluded = true
                existing.isQuickSkipped = true
                existing.lastTouchedAt = now
                existing.touchSequence = seq
                signals[cleanId] = existing
            } else {
                signals[cleanId] = TrackSignal(
                    anchor: SavedWaveAnchorTrack(from: track),
                    score: -10.0,
                    lastTouchedAt: now,
                    touchSequence: seq,
                    isHardExcluded: true,
                    isQuickSkipped: true,
                    isFromBaselinePreset: false
                )
            }
            excludedIdsOrder.removeAll { $0 == cleanId }
            excludedIdsOrder.append(cleanId)
            if excludedIdsOrder.count > 30 {
                excludedIdsOrder.removeFirst(excludedIdsOrder.count - 30)
            }
            if baselinePreset != nil {
                hasPendingStyleDrift = true
            }
        }
    }

    // MARK: - Snapshot Candidate Builder

    public func buildCandidateSnapshot(
        currentTrack: YMTrack?,
        queue: [YMTrack],
        currentIndex: Int,
        context: YMWaveContext,
        vibe: YMWaveVibePreset
    ) -> WaveSnapshotCandidate {
        var workingSignals = signals

        if let current = currentTrack, !current.isPlaceholder, !current.isSpacer {
            let cleanCurrent = Self.cleanTrackId(from: current.id)
            if var existing = workingSignals[cleanCurrent] {
                if !existing.isHardExcluded && !existing.isQuickSkipped {
                    existing.score = Self.clamped(existing.score + 2.0)
                    existing.touchSequence = touchCounter &+ 1
                    existing.lastTouchedAt = Date()
                    workingSignals[cleanCurrent] = existing
                }
            } else if !excludedIdsOrder.contains(cleanCurrent) {
                workingSignals[cleanCurrent] = TrackSignal(
                    anchor: SavedWaveAnchorTrack(from: current),
                    score: 2.0,
                    lastTouchedAt: Date(),
                    touchSequence: touchCounter &+ 1,
                    isHardExcluded: false,
                    isQuickSkipped: false,
                    isFromBaselinePreset: false
                )
            }
        }

        let eligible = workingSignals.values.filter { sig in
            !sig.isHardExcluded && !sig.isQuickSkipped && sig.score > 0
        }

        // Strict weak ordering using bucketed score (0.5 granularity), fresh-vs-baseline priority, and recency.
        let sorted = eligible.sorted { lhs, rhs in
            let lhsRank = rankKey(for: lhs)
            let rhsRank = rankKey(for: rhs)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            return lhs.anchor.id < rhs.anchor.id
        }

        var selectedAnchors: [SavedWaveAnchorTrack] = []
        var selectedIds = Set<String>()
        var artistCounts: [String: Int] = [:]

        // Pass 1: diversify artists (max 2 per artist)
        for item in sorted {
            guard selectedAnchors.count < 5 else { break }
            let artistKey = Self.artistBucketKey(for: item.anchor)
            if artistCounts[artistKey, default: 0] >= 2 {
                continue
            }
            selectedAnchors.append(item.anchor)
            selectedIds.insert(item.anchor.id)
            artistCounts[artistKey, default: 0] += 1
        }

        // Pass 2: if fewer than 5 and no other artists are available, top up with remaining positive candidates
        if selectedAnchors.count < 5 {
            for item in sorted where !selectedIds.contains(item.anchor.id) {
                guard selectedAnchors.count < 5 else { break }
                selectedAnchors.append(item.anchor)
                selectedIds.insert(item.anchor.id)
            }
        }

        // Pass 3: instant save fallback on early tracks (< 3 anchors) using upcoming queue tracks
        if selectedAnchors.count < 3 && !queue.isEmpty {
            let safeStart = max(0, min(currentIndex, queue.count - 1))
            let tailSlice = queue[safeStart...]
            let hardExcluded = Set(excludedIdsOrder)

            for track in tailSlice {
                guard selectedAnchors.count < 5 else { break }
                guard !track.isPlaceholder, !track.isSpacer else { continue }
                let cleanId = Self.cleanTrackId(from: track.id)
                if selectedIds.contains(cleanId) || hardExcluded.contains(cleanId) { continue }
                if let sig = workingSignals[cleanId], sig.isHardExcluded || sig.isQuickSkipped { continue }

                let anchor = SavedWaveAnchorTrack(from: track)
                let artistKey = Self.artistBucketKey(for: anchor)
                if artistCounts[artistKey, default: 0] >= 2 { continue }

                selectedAnchors.append(anchor)
                selectedIds.insert(cleanId)
                artistCounts[artistKey, default: 0] += 1
            }

            if selectedAnchors.count < 3 {
                for track in tailSlice {
                    guard selectedAnchors.count < 5 else { break }
                    guard !track.isPlaceholder, !track.isSpacer else { continue }
                    let cleanId = Self.cleanTrackId(from: track.id)
                    if selectedIds.contains(cleanId) || hardExcluded.contains(cleanId) { continue }
                    if let sig = workingSignals[cleanId], sig.isHardExcluded || sig.isQuickSkipped { continue }

                    selectedAnchors.append(SavedWaveAnchorTrack(from: track))
                    selectedIds.insert(cleanId)
                }
            }
        }

        let resolvedSeeds: [String]
        let resolvedTitle: String
        let resolvedFallback: String
        if let base = baselinePreset {
            resolvedSeeds = Self.extractCleanBaseSeeds(from: base.baseContextSeeds)
            resolvedTitle = base.baseContextTitle
            resolvedFallback = base.baseFallbackStationId
        } else {
            let contextClean = Self.extractCleanBaseSeeds(from: context.seeds)
            resolvedSeeds = contextClean.isEmpty ? cleanBaseSeeds : contextClean
            resolvedTitle = context.title == "Моя волна" ? cleanBaseTitle : context.title
            resolvedFallback = context.fallbackStationId.hasPrefix("track:")
                ? cleanBaseFallbackStationId
                : context.fallbackStationId
        }

        return WaveSnapshotCandidate(
            baseContextSeeds: resolvedSeeds,
            baseContextTitle: resolvedTitle,
            baseFallbackStationId: resolvedFallback,
            vibe: vibe,
            anchorTracks: selectedAnchors,
            excludedTrackIds: excludedIdsOrder
        )
    }

    // MARK: - Helpers

    private func recordPositiveSignalBoost(
        for track: YMTrack,
        delta: Double,
        markDrift: Bool,
        at now: Date,
        seq: UInt64
    ) {
        let cleanId = Self.cleanTrackId(from: track.id)
        consecutiveQuickSkips = 0
        excludedIdsOrder.removeAll { $0 == cleanId }
        if var existing = signals[cleanId] {
            existing.score = Self.clamped(existing.score + delta)
            existing.isHardExcluded = false
            existing.isQuickSkipped = false
            existing.lastTouchedAt = now
            existing.touchSequence = seq
            if existing.anchor.coverUri == nil, track.effectiveCoverUri != nil {
                existing.anchor = SavedWaveAnchorTrack(from: track)
            }
            signals[cleanId] = existing
        } else {
            signals[cleanId] = TrackSignal(
                anchor: SavedWaveAnchorTrack(from: track),
                score: Self.clamped(delta),
                lastTouchedAt: now,
                touchSequence: seq,
                isHardExcluded: false,
                isQuickSkipped: false,
                isFromBaselinePreset: false
            )
        }
        if markDrift && baselinePreset != nil {
            hasPendingStyleDrift = true
        }
    }

    private func rankKey(for signal: TrackSignal) -> (Int, Int, Double, UInt64) {
        let isNewStrong = (!signal.isFromBaselinePreset && signal.score >= 2.0) ? 1 : 0
        let effectiveScore = signal.score + (isNewStrong == 1 ? 0.5 : 0.0)
        let bucket = Int(floor(effectiveScore * 2.0))
        return (bucket, isNewStrong, effectiveScore, signal.touchSequence)
    }

    private static func clamped(_ value: Double) -> Double {
        max(-12.0, min(12.0, value))
    }

    private static func cleanTrackId(from id: String) -> String {
        if let colon = id.firstIndex(of: ":") {
            let prefix = id[..<colon]
            return prefix.isEmpty ? id : String(prefix)
        }
        return id
    }

    private static func extractCleanBaseSeeds(from seeds: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for seed in seeds {
            guard !seed.isEmpty, !seed.hasPrefix("track:") else { continue }
            if seen.insert(seed).inserted {
                result.append(seed)
            }
        }
        if result.isEmpty {
            return ["user:onyourwave"]
        }
        return result
    }

    private static func artistBucketKey(for anchor: SavedWaveAnchorTrack) -> String {
        if let artistId = anchor.artistId, !artistId.isEmpty {
            return "id:\(artistId)"
        }
        let normalizedName = anchor.artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedName.isEmpty && normalizedName != "unknown artist" {
            return "name:\(normalizedName)"
        }
        return "track:\(anchor.id)"
    }
}
