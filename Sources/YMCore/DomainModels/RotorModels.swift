import Foundation

// MARK: - Rotor Station Response Models

public struct YMRotorStationTracksResult: Codable, Sendable {
    public let radioSessionId: String?
    public let batchId: String?
    public let sequence: [YMRotorSequenceItem]

    enum CodingKeys: String, CodingKey {
        case radioSessionId
        case radioSessionIdKebab = "radio-session-id"
        case batchId
        case batchIdKebab = "batch-id"
        case sequence
    }

    public init(radioSessionId: String? = nil, batchId: String?, sequence: [YMRotorSequenceItem] = []) {
        self.radioSessionId = radioSessionId
        self.batchId = batchId
        self.sequence = sequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // radioSessionId can come as camelCase or kebab-case
        if let sessionId = try? container.decodeIfPresent(String.self, forKey: .radioSessionId) {
            self.radioSessionId = sessionId
        } else {
            self.radioSessionId = try? container.decodeIfPresent(String.self, forKey: .radioSessionIdKebab)
        }

        // batchId can come as camelCase or kebab-case
        if let id = try? container.decodeIfPresent(String.self, forKey: .batchId) {
            self.batchId = id
        } else {
            self.batchId = try? container.decodeIfPresent(String.self, forKey: .batchIdKebab)
        }

        self.sequence = (try? container.decodeIfPresent([YMRotorSequenceItem].self, forKey: .sequence)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(radioSessionId, forKey: .radioSessionId)
        try container.encodeIfPresent(batchId, forKey: .batchId)
        try container.encode(sequence, forKey: .sequence)
    }
}

public struct YMRotorSequenceItem: Codable, Sendable {
    public let type: String?
    public let track: YMTrack?

    enum CodingKeys: String, CodingKey {
        case type
        case track
    }
}

// MARK: - Rotor Session v2 Request Models

public struct YMRotorSessionNewRequest: Codable, Sendable {
    public let seeds: [String]
    public let includeTracksInResponse: Bool
    public let includeWaveModel: Bool
    public let interactive: Bool

    public init(
        seeds: [String] = ["user:onyourwave"],
        includeTracksInResponse: Bool = true,
        includeWaveModel: Bool = true,
        interactive: Bool = true
    ) {
        self.seeds = seeds
        self.includeTracksInResponse = includeTracksInResponse
        self.includeWaveModel = includeWaveModel
        self.interactive = interactive
    }
}

public struct YMRotorSessionNextTracksRequest: Codable, Sendable {
    public let queue: [String]

    public init(queue: [String]) {
        self.queue = queue
    }
}

public struct YMRotorSessionFeedbackRequest: Codable, Sendable {
    public let event: YMRotorFeedbackEvent
    public let batchId: String?

    public init(event: YMRotorFeedbackEvent, batchId: String?) {
        self.event = event
        self.batchId = batchId
    }
}

// MARK: - Rotor Feedback Telemetry Models

public enum YMRotorEventType: String, Codable, Sendable {
    case radioStarted
    case trackStarted
    case trackFinished
    case skip
    case like
    case dislike
}

public struct YMRotorFeedbackPayload: Codable, Sendable {
    public let event: YMRotorFeedbackEvent

    public init(event: YMRotorFeedbackEvent) {
        self.event = event
    }
}

public struct YMRotorFeedbackEvent: Codable, Sendable {
    public let type: YMRotorEventType
    public let timestamp: String
    public let trackId: String?
    public let totalPlayedSeconds: Double?
    public let from: String

    public init(
        type: YMRotorEventType,
        timestamp: String,
        trackId: String?,
        totalPlayedSeconds: Double? = nil,
        from: String = "mobile-home-rup_main-user-onyourwave-default"
    ) {
        self.type = type
        self.timestamp = timestamp
        self.trackId = trackId
        self.totalPlayedSeconds = totalPlayedSeconds
        self.from = from
    }
}

// MARK: - Wave Vibe & Context Models

public enum YMWaveVibePreset: String, CaseIterable, Identifiable, Sendable {
    case defaultWave = "default"
    case energetic = "energetic"
    case unfamiliar = "discover"
    case familiar = "favorite"
    case popular = "popular"
    case calm = "calm"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultWave: return "По умолчанию"
        case .energetic: return "Энергичное"
        case .unfamiliar: return "Незнакомое"
        case .familiar: return "Знакомое"
        case .popular: return "Популярное"
        case .calm: return "Спокойное"
        }
    }

    public var iconName: String {
        switch self {
        case .defaultWave: return "waveform.path.ecg"
        case .energetic: return "bolt.fill"
        case .unfamiliar: return "sparkles"
        case .familiar: return "heart.circle"
        case .popular: return "flame.fill"
        case .calm: return "moon.stars.fill"
        }
    }

    public var seedParameter: String? {
        switch self {
        case .defaultWave: return nil
        case .energetic: return "mood:energize"
        case .unfamiliar: return "settingDiversity:discover"
        case .familiar: return "settingDiversity:favorite"
        case .popular: return "settingDiversity:popular"
        case .calm: return "mood:calm"
        }
    }
}

public enum YMWaveTuningSignal: Sendable {
    case moreLikeThis     // Тихий сигнал "like" + "trackFinished" (без добавления в Избранное)
    case lessLikeThis     // Тихий сигнал "dislike" + "skip" и мгновенный переход к следующему треку
    case moreDiversity    // Пересборка очереди с упором на незнакомые треки
}

public struct YMWaveContext: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let seeds: [String]
    public let fallbackStationId: String

    public init(
        title: String,
        subtitle: String,
        seeds: [String],
        fallbackStationId: String = "user:onyourwave"
    ) {
        self.title = title
        self.subtitle = subtitle
        self.seeds = seeds
        self.fallbackStationId = fallbackStationId
    }

    public static let myWaveDefault = YMWaveContext(
        title: "Моя волна",
        subtitle: "Бесконечный персональный поток музыки под ваше настроение",
        seeds: ["user:onyourwave"],
        fallbackStationId: "user:onyourwave"
    )

    public static func forTrack(_ track: YMTrack) -> YMWaveContext {
        YMWaveContext(
            title: "Волна по треку: \(track.title)",
            subtitle: "Похожее на \(track.artistsString) — \(track.displayTitle)",
            seeds: ["track:\(track.id)"],
            fallbackStationId: "track:\(track.id)"
        )
    }

    public static func forPlaylist(_ playlist: YMPlaylist, sampleTrackIds: [String] = []) -> YMWaveContext {
        let primarySeed = "playlist:\(playlist.uid)_\(playlist.kind)"
        let fallbackSeeds = sampleTrackIds.prefix(5).map { "track:\($0)" }
        let effectiveSeeds = [primarySeed] + fallbackSeeds
        return YMWaveContext(
            title: "Волна по плейлисту: \(playlist.title)",
            subtitle: "Треки в стиле плейлиста «\(playlist.title)»",
            seeds: effectiveSeeds,
            fallbackStationId: "user:onyourwave"
        )
    }

    public static func forArtist(_ artist: YMArtist) -> YMWaveContext {
        YMWaveContext(
            title: "Волна по артисту: \(artist.name)",
            subtitle: "Лучшие треки \(artist.name) и похожая музыка",
            seeds: ["artist:\(artist.id)"],
            fallbackStationId: "artist:\(artist.id)"
        )
    }
}
