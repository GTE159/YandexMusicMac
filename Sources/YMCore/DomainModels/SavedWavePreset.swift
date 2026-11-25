import Foundation

/// Lightweight snapshot of an anchor track defining a saved wave's musical vector.
/// Avoids retaining nested `YMTrack` metadata graphs in memory or on disk.
public struct SavedWaveAnchorTrack: Codable, Sendable, Identifiable, Hashable {
    public let id: String            // clean numeric trackId
    public let albumId: String?
    public let title: String
    public let artistId: String?
    public let artistName: String
    public let coverUri: String?

    public var rotorTrackId: String {
        if let albumId, !albumId.isEmpty {
            return "\(id):\(albumId)"
        }
        return id
    }

    public init(
        id: String,
        albumId: String? = nil,
        title: String,
        artistId: String? = nil,
        artistName: String,
        coverUri: String? = nil
    ) {
        self.id = id
        self.albumId = albumId
        self.title = title
        self.artistId = artistId
        self.artistName = artistName
        self.coverUri = coverUri
    }

    public init(from track: YMTrack) {
        let cleanId = track.id.components(separatedBy: ":").first ?? track.id
        self.id = cleanId
        self.albumId = track.primaryAlbumId
        self.title = track.displayTitle
        self.artistId = track.artists.first?.id
        self.artistName = track.artistsString
        self.coverUri = track.effectiveCoverUri
    }
}

/// Curated SF Symbol icons for user-saved wave presets.
public enum SavedWaveIcon: String, CaseIterable, Codable, Sendable, Identifiable {
    case briefcase = "briefcase.fill"
    case headphones = "headphones"
    case moon = "moon.stars.fill"
    case bolt = "bolt.fill"
    case flame = "flame.fill"
    case leaf = "leaf.fill"
    case car = "car.fill"
    case gamecontroller = "gamecontroller.fill"
    case sparkles = "sparkles"
    case heart = "heart.fill"
    case cup = "cup.and.saucer.fill"
    case waveform = "waveform.path.ecg"

    public var id: String { rawValue }
}

/// Immutable snapshot of a specific direction and mood of "Моя волна".
/// Never modified automatically by playback, skips, likes, dislikes, or sign-out —
/// updates strictly on explicit user action (create / overwrite / metadata edit).
public struct SavedWavePreset: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let ownerUid: String
    public var name: String
    public var icon: SavedWaveIcon
    public var accentHex: String

    /// Base non-track context seeds (e.g., ["genre:electronic"] or ["mood:calm"]).
    /// Preserved cleanly across overwrites to prevent recursive track seed growth.
    public var baseContextSeeds: [String]
    public var baseContextTitle: String
    public var baseFallbackStationId: String

    /// Active wave mood / diversity / language modifier.
    public var vibe: YMWaveVibePreset

    /// 1...5 diversified anchor tracks defining the specific artist/track direction.
    public var anchorTracks: [SavedWaveAnchorTrack]

    /// Up to 30 clean numeric track IDs explicitly rejected ("Меньше таких" / instant dislike)
    /// when saving this snapshot, filtered out when starting this wave.
    public var excludedTrackIds: [String]

    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        ownerUid: String,
        name: String,
        icon: SavedWaveIcon = .waveform,
        accentHex: String = "#F2C12E",
        baseContextSeeds: [String],
        baseContextTitle: String,
        baseFallbackStationId: String,
        vibe: YMWaveVibePreset,
        anchorTracks: [SavedWaveAnchorTrack],
        excludedTrackIds: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.name = name
        self.icon = icon
        self.accentHex = accentHex
        self.baseContextSeeds = baseContextSeeds
        self.baseContextTitle = baseContextTitle
        self.baseFallbackStationId = baseFallbackStationId
        self.vibe = vibe
        self.anchorTracks = anchorTracks
        self.excludedTrackIds = excludedTrackIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Concise human-readable style summary for wave cards (e.g., "Спокойное · Tycho, Bonobo").
    public var styleSummary: String {
        var parts: [String] = []
        if vibe != .defaultWave {
            parts.append(vibe.title)
        } else if !baseContextTitle.isEmpty && baseContextTitle != "Моя волна" {
            parts.append(baseContextTitle)
        }
        var uniqueArtists: [String] = []
        for anchor in anchorTracks {
            let cleanName = anchor.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanName.isEmpty && cleanName != "Unknown Artist" && !uniqueArtists.contains(cleanName) {
                uniqueArtists.append(cleanName)
                if uniqueArtists.count >= 2 { break }
            }
        }
        if !uniqueArtists.isEmpty {
            parts.append(uniqueArtists.joined(separator: ", "))
        }
        if parts.isEmpty {
            return "Персональный снимок волны"
        }
        return parts.joined(separator: " · ")
    }

    public var primaryCoverUri: String? {
        anchorTracks.first(where: { $0.coverUri != nil })?.coverUri
    }
}

/// Ephemeral playback and tuning outcomes emitted by `AudioPlayerEngine` / `LikesService`
/// while wave mode is active, consumed in-memory by `WaveSessionTasteTracker`.
public enum YMWaveTrackOutcome: Sendable {
    case started
    case finished(playedSeconds: Double)
    case skipped(playedSeconds: Double)
    case liked
    case moreLikeThis
    case lessLikeThis
}
