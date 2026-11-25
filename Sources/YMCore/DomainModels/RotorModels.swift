import Foundation
import Observation

// MARK: - Rotor API Mode & Diagnostics

public extension Notification.Name {
    static let rotorDiagnosticsDidUpdate = Notification.Name("com.yandexmusic.mac.rotorDiagnosticsDidUpdate")
}

/// User-selectable protocol strategy for "Моя волна" (Rotor API).
public enum YMRotorAPIMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case v2Only = "v2Only"
    case v1Fallback = "v1Fallback"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Авто (Session v2 → Radio v1)"
        case .v2Only: return "Только Rotor Session v2"
        case .v1Fallback: return "Классический Rotor Radio v1"
        }
    }
}

/// Real-time diagnostics snapshot for Rotor API protocol selection, fallback level, and deduplication stats.
public struct YMRotorDiagnostics: Sendable, Equatable {
    public var activeProtocol: String
    public var isFallbackActive: Bool
    /// 0 = idle, 1 = Session v2, 2 = Session v2 Simplified, 3 = Station v1, 4 = Base Wave Fallback
    public var activeLevel: Int
    public var sessionId: String?
    public var batchId: String?
    public var activeSeeds: [String]
    public var fetchedTracksCount: Int
    public var filteredDuplicatesCount: Int
    public var lastFallbackReason: String?
    public var lastUpdated: Date?

    public init(
        activeProtocol: String = "Не запущена",
        isFallbackActive: Bool = false,
        activeLevel: Int = 0,
        sessionId: String? = nil,
        batchId: String? = nil,
        activeSeeds: [String] = [],
        fetchedTracksCount: Int = 0,
        filteredDuplicatesCount: Int = 0,
        lastFallbackReason: String? = nil,
        lastUpdated: Date? = nil
    ) {
        self.activeProtocol = activeProtocol
        self.isFallbackActive = isFallbackActive
        self.activeLevel = activeLevel
        self.sessionId = sessionId
        self.batchId = batchId
        self.activeSeeds = activeSeeds
        self.fetchedTracksCount = fetchedTracksCount
        self.filteredDuplicatesCount = filteredDuplicatesCount
        self.lastFallbackReason = lastFallbackReason
        self.lastUpdated = lastUpdated
    }
}

/// Track-level acoustic parameters returned by Rotor API sequence items.
public struct YMRotorTrackParameters: Codable, Sendable, Equatable {
    public let bpm: Double?
    public let hue: Double?
    public let energy: Double?

    public init(bpm: Double? = nil, hue: Double? = nil, energy: Double? = nil) {
        self.bpm = bpm
        self.hue = hue
        self.energy = energy
    }
}

/// Compact per-track recommendation metadata cached for UI insights in `MyWaveView`.
public struct YMRotorTrackInsight: Sendable, Equatable {
    public let trackParameters: YMRotorTrackParameters?
    public let description: String?
    public let waveText: String?

    public init(
        trackParameters: YMRotorTrackParameters? = nil,
        description: String? = nil,
        waveText: String? = nil
    ) {
        self.trackParameters = trackParameters
        self.description = description
        self.waveText = waveText
    }

    public var formattedInsight: String? {
        if let waveText = waveText?.trimmingCharacters(in: .whitespacesAndNewlines), !waveText.isEmpty {
            return waveText
        }
        if let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            return desc
        }
        if let params = trackParameters {
            let bpmInt = params.bpm.map { Int($0.rounded()) }
            if let bpm = bpmInt, bpm > 0 {
                if let energy = params.energy {
                    if energy >= 0.72 {
                        return "Высокая энергия • \(bpm) BPM"
                    } else if energy <= 0.35 {
                        return "Спокойный темп • \(bpm) BPM"
                    }
                }
                return "Поток Моей волны • \(bpm) BPM"
            }
        }
        return nil
    }
}

/// MainActor observable mirror of `RotorService` diagnostics, preferred API mode, and bounded track insights.
@Observable
@MainActor
public final class RotorDiagnosticsStore {
    public static let shared = RotorDiagnosticsStore()

    private static let apiModeKey = "ym_rotor_api_mode"

    public var diagnostics: YMRotorDiagnostics = YMRotorDiagnostics()
    public var preferredAPIMode: YMRotorAPIMode {
        didSet {
            UserDefaults.standard.set(preferredAPIMode.rawValue, forKey: Self.apiModeKey)
        }
    }

    private var trackInsights: [String: YMRotorTrackInsight] = [:]
    private var insightOrder: [String] = []
    private let maxCachedInsights = 150

    public init() {
        if let raw = UserDefaults.standard.string(forKey: Self.apiModeKey),
           let saved = YMRotorAPIMode(rawValue: raw) {
            self.preferredAPIMode = saved
        } else {
            self.preferredAPIMode = .auto
        }
    }

    public func updateDiagnostics(_ newDiagnostics: YMRotorDiagnostics) {
        self.diagnostics = newDiagnostics
        NotificationCenter.default.post(name: .rotorDiagnosticsDidUpdate, object: newDiagnostics)
    }

    public func recordTrackInsights(_ items: [(trackId: String, insight: YMRotorTrackInsight)]) {
        for (trackId, insight) in items {
            if trackInsights[trackId] == nil {
                insightOrder.append(trackId)
            }
            trackInsights[trackId] = insight
        }
        if insightOrder.count > maxCachedInsights {
            let overflow = insightOrder.count - maxCachedInsights
            for oldId in insightOrder.prefix(overflow) {
                trackInsights.removeValue(forKey: oldId)
            }
            insightOrder.removeFirst(overflow)
        }
    }

    public func insight(for trackId: String) -> YMRotorTrackInsight? {
        if let direct = trackInsights[trackId] {
            return direct
        }
        let cleanId = trackId.components(separatedBy: ":").first ?? trackId
        return trackInsights[cleanId]
    }
}

// MARK: - Rotor Station Response Models

public struct YMRotorStationTracksResult: Codable, Sendable {
    public let radioSessionId: String?
    public let batchId: String?
    public let sequence: [YMRotorSequenceItem]
    public let terminated: Bool?
    public let unknownSession: Bool?
    public let pumpkin: Bool?

    enum CodingKeys: String, CodingKey {
        case radioSessionId
        case radioSessionIdKebab = "radio-session-id"
        case batchId
        case batchIdKebab = "batch-id"
        case sequence
        case terminated
        case unknownSession
        case unknownSessionKebab = "unknown-session"
        case pumpkin
    }

    public init(
        radioSessionId: String? = nil,
        batchId: String?,
        sequence: [YMRotorSequenceItem] = [],
        terminated: Bool? = nil,
        unknownSession: Bool? = nil,
        pumpkin: Bool? = nil
    ) {
        self.radioSessionId = radioSessionId
        self.batchId = batchId
        self.sequence = sequence
        self.terminated = terminated
        self.unknownSession = unknownSession
        self.pumpkin = pumpkin
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
        self.terminated = try? container.decodeIfPresent(Bool.self, forKey: .terminated)

        if let unk = try? container.decodeIfPresent(Bool.self, forKey: .unknownSession) {
            self.unknownSession = unk
        } else {
            self.unknownSession = try? container.decodeIfPresent(Bool.self, forKey: .unknownSessionKebab)
        }

        self.pumpkin = try? container.decodeIfPresent(Bool.self, forKey: .pumpkin)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(radioSessionId, forKey: .radioSessionId)
        try container.encodeIfPresent(batchId, forKey: .batchId)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(terminated, forKey: .terminated)
        try container.encodeIfPresent(unknownSession, forKey: .unknownSession)
        try container.encodeIfPresent(pumpkin, forKey: .pumpkin)
    }
}

public struct YMRotorSequenceItem: Codable, Sendable {
    public let type: String?
    public let track: YMTrack?
    public let trackParameters: YMRotorTrackParameters?
    public let description: String?
    public let waveText: String?

    enum CodingKeys: String, CodingKey {
        case type
        case track
        case trackParameters
        case description
        case waveText
    }

    public init(
        type: String? = nil,
        track: YMTrack? = nil,
        trackParameters: YMRotorTrackParameters? = nil,
        description: String? = nil,
        waveText: String? = nil
    ) {
        self.type = type
        self.track = track
        self.trackParameters = trackParameters
        self.description = description
        self.waveText = waveText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try? container.decodeIfPresent(String.self, forKey: .type)
        self.track = try? container.decodeIfPresent(YMTrack.self, forKey: .track)
        self.trackParameters = try? container.decodeIfPresent(YMRotorTrackParameters.self, forKey: .trackParameters)
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.waveText = try? container.decodeIfPresent(String.self, forKey: .waveText)
    }
}

// MARK: - Personal Wave Stations (Dashboard & Stations List)

public struct YMPersonalWaveStation: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let tag: String
    public let title: String
    public let subtitle: String?
    public let iconUrl: String?
    public let accentHex: String?
    public let combineWithMyWave: Bool
    public let idForFrom: String?

    public init(
        type: String,
        tag: String,
        title: String,
        subtitle: String? = nil,
        iconUrl: String? = nil,
        accentHex: String? = nil,
        combineWithMyWave: Bool? = nil,
        idForFrom: String? = nil
    ) {
        self.type = type
        self.tag = tag
        self.id = "\(type):\(tag)"
        self.title = title
        self.subtitle = subtitle
        self.iconUrl = iconUrl
        self.accentHex = accentHex
        self.idForFrom = idForFrom
        if let explicit = combineWithMyWave {
            self.combineWithMyWave = explicit
        } else {
            self.combineWithMyWave = ["genre", "mood", "activity", "epoch"].contains(type.lowercased())
        }
    }

    public func toWaveContext() -> YMWaveContext {
        YMWaveContext(
            title: title,
            subtitle: subtitle ?? "Персональная волна «\(title)»",
            seeds: [id],
            fallbackStationId: id,
            idForFrom: idForFrom
        )
    }

    public var categoryLabel: String {
        switch type.lowercased() {
        case "genre": return "Жанр"
        case "mood": return "Настроение"
        case "activity": return "Занятие"
        case "epoch": return "Эпоха"
        case "artist": return "Исполнитель"
        default: return "Волна"
        }
    }

    public var fallbackIconName: String {
        switch type.lowercased() {
        case "genre": return "guitars.fill"
        case "mood": return "sparkles"
        case "activity": return "figure.walk"
        case "epoch": return "clock.arrow.circlepath"
        case "artist": return "music.mic"
        default: return "waveform.path.ecg"
        }
    }
}

public struct YMRotorStationId: Codable, Sendable {
    public let type: String
    public let tag: String

    public init(type: String, tag: String) {
        self.type = type
        self.tag = tag
    }
}

public struct YMRotorStationIcon: Codable, Sendable {
    public let backgroundColor: String?
    public let imageUrl: String?

    public init(backgroundColor: String? = nil, imageUrl: String? = nil) {
        self.backgroundColor = backgroundColor
        self.imageUrl = imageUrl
    }
}

public struct YMRotorStationInfo: Codable, Sendable {
    public let id: YMRotorStationId?
    public let name: String?
    public let icon: YMRotorStationIcon?
    public let fullImageUrl: String?
    public let idForFrom: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case icon
        case fullImageUrl
        case idForFrom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try? container.decodeIfPresent(YMRotorStationId.self, forKey: .id)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.icon = try? container.decodeIfPresent(YMRotorStationIcon.self, forKey: .icon)
        self.fullImageUrl = try? container.decodeIfPresent(String.self, forKey: .fullImageUrl)
        self.idForFrom = try? container.decodeIfPresent(String.self, forKey: .idForFrom)
    }

    public func toPersonalWaveStation(
        subtitle: String? = nil,
        overrideTitle: String? = nil,
        customName: String? = nil
    ) -> YMPersonalWaveStation? {
        guard let stationId = id, !stationId.type.isEmpty, !stationId.tag.isEmpty else {
            return nil
        }

        // Priority: customName -> station.name -> rupTitle, discarding empty strings and generic "Моя волна"
        let cleanCustom = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOverride = overrideTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedTitle: String
        if let cleanCustom, !cleanCustom.isEmpty, cleanCustom.caseInsensitiveCompare("Моя волна") != .orderedSame {
            resolvedTitle = cleanCustom
        } else if let cleanName, !cleanName.isEmpty, cleanName.caseInsensitiveCompare("Моя волна") != .orderedSame {
            resolvedTitle = cleanName
        } else if let cleanOverride, !cleanOverride.isEmpty, cleanOverride.caseInsensitiveCompare("Моя волна") != .orderedSame {
            resolvedTitle = cleanOverride
        } else if let cleanCustom, !cleanCustom.isEmpty {
            resolvedTitle = cleanCustom
        } else if let cleanName, !cleanName.isEmpty {
            resolvedTitle = cleanName
        } else {
            resolvedTitle = stationId.tag
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }

        return YMPersonalWaveStation(
            type: stationId.type,
            tag: stationId.tag,
            title: resolvedTitle,
            subtitle: subtitle,
            iconUrl: icon?.imageUrl ?? fullImageUrl,
            accentHex: icon?.backgroundColor,
            idForFrom: idForFrom
        )
    }
}

public struct YMRotorDashboardStationItem: Codable, Sendable {
    public let station: YMRotorStationInfo?
    public let rupTitle: String?
    public let rupDescription: String?
    public let explanation: String?
    public let customName: String?

    enum CodingKeys: String, CodingKey {
        case station
        case rupTitle
        case rupDescription
        case explanation
        case customName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try? container.decodeIfPresent(YMRotorStationInfo.self, forKey: .station) {
            self.station = wrapped
        } else {
            // Support flat station objects returned by some /rotor/stations/list variants
            self.station = try? YMRotorStationInfo(from: decoder)
        }
        self.rupTitle = try? container.decodeIfPresent(String.self, forKey: .rupTitle)
        self.rupDescription = try? container.decodeIfPresent(String.self, forKey: .rupDescription)
        self.explanation = try? container.decodeIfPresent(String.self, forKey: .explanation)
        self.customName = try? container.decodeIfPresent(String.self, forKey: .customName)
    }

    public func toPersonalWaveStation() -> YMPersonalWaveStation? {
        let subtitle = (rupDescription?.isEmpty == false ? rupDescription : nil)
            ?? (explanation?.isEmpty == false ? explanation : nil)
        return station?.toPersonalWaveStation(
            subtitle: subtitle,
            overrideTitle: rupTitle,
            customName: customName
        )
    }
}

public struct YMRotorDashboardResponse: Codable, Sendable {
    public let dashboardId: String?
    public let stations: [YMRotorDashboardStationItem]

    enum CodingKeys: String, CodingKey {
        case dashboardId
        case stations
    }

    public init(dashboardId: String? = nil, stations: [YMRotorDashboardStationItem] = []) {
        self.dashboardId = dashboardId
        self.stations = stations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dashboardId = try? container.decodeIfPresent(String.self, forKey: .dashboardId)
        self.stations = (try? container.decodeIfPresent([YMRotorDashboardStationItem].self, forKey: .stations)) ?? []
    }
}

// MARK: - Rotor Session v2 Request Models

public struct YMRotorSessionNewRequest: Codable, Sendable {
    public let seeds: [String]
    public let includeTracksInResponse: Bool
    public let includeWaveModel: Bool
    public let interactive: Bool
    public let queue: [String]?

    public init(
        seeds: [String] = ["user:onyourwave"],
        includeTracksInResponse: Bool = true,
        includeWaveModel: Bool = true,
        interactive: Bool = true,
        queue: [String]? = nil
    ) {
        self.seeds = seeds
        self.includeTracksInResponse = includeTracksInResponse
        self.includeWaveModel = includeWaveModel
        self.interactive = interactive
        self.queue = queue
    }
}

public struct YMRotorSessionNextTracksRequest: Codable, Sendable {
    public let queue: [String]
    public let batchId: String?

    public init(queue: [String], batchId: String? = nil) {
        self.queue = queue
        self.batchId = batchId
    }

    enum CodingKeys: String, CodingKey {
        case queue
        case batchId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(queue, forKey: .queue)
        try container.encodeIfPresent(batchId, forKey: .batchId)
    }
}

public struct YMRotorSessionEvent: Codable, Sendable {
    public let type: YMRotorEventType
    public let timestamp: String
    public let trackId: String?
    public let totalPlayedSeconds: Double?

    public init(
        type: YMRotorEventType,
        timestamp: String,
        trackId: String? = nil,
        totalPlayedSeconds: Double? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.trackId = trackId
        self.totalPlayedSeconds = totalPlayedSeconds
    }
}

public struct YMRotorSessionFeedbackRequest: Codable, Sendable {
    public let event: YMRotorSessionEvent
    public let batchId: String?
    public let from: String?

    public init(event: YMRotorSessionEvent, batchId: String? = nil, from: String? = nil) {
        self.event = event
        self.batchId = batchId
        self.from = from
    }
}

public struct YMRotorStationFeedbackRequest: Codable, Sendable {
    public let type: YMRotorEventType
    public let timestamp: String
    public let trackId: String?
    public let totalPlayedSeconds: Double?
    public let from: String?

    public init(
        type: YMRotorEventType,
        timestamp: String,
        trackId: String? = nil,
        totalPlayedSeconds: Double? = nil,
        from: String? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.trackId = trackId
        if let played = totalPlayedSeconds, played > 0 {
            self.totalPlayedSeconds = played
        } else {
            self.totalPlayedSeconds = nil
        }
        self.from = from
    }

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case trackId
        case totalPlayedSeconds
        case from
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(trackId, forKey: .trackId)
        if let totalPlayed = totalPlayedSeconds, totalPlayed > 0 {
            try container.encode(totalPlayed, forKey: .totalPlayedSeconds)
        }
        try container.encodeIfPresent(from, forKey: .from)
    }
}

// MARK: - Rotor Feedback Telemetry Models (Compatibility)

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

public enum YMWaveVibePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case defaultWave = "default"
    case energetic = "energetic"
    case unfamiliar = "discover"
    case familiar = "favorite"
    case popular = "popular"
    case calm = "calm"
    case joyful = "fun"
    case sad = "sad"
    case russian = "russian"
    case foreign = "not-russian"
    case focus = "work"
    case workout = "sport"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultWave: return "По умолчанию"
        case .energetic: return "Энергичное"
        case .unfamiliar: return "Незнакомое"
        case .familiar: return "Знакомое"
        case .popular: return "Популярное"
        case .calm: return "Спокойное"
        case .joyful: return "Радостное"
        case .sad: return "Грустное"
        case .russian: return "На русском"
        case .foreign: return "Иностранное"
        case .focus: return "Для фокуса"
        case .workout: return "Тренировка"
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
        case .joyful: return "sun.max.fill"
        case .sad: return "cloud.rain.fill"
        case .russian: return "character.bubble.fill"
        case .foreign: return "globe"
        case .focus: return "brain.head.profile"
        case .workout: return "figure.run"
        }
    }

    public var seedParameter: String? {
        switch self {
        case .defaultWave: return nil
        case .energetic: return "settingMoodEnergy:active"
        case .unfamiliar: return "settingDiversity:discover"
        case .familiar: return "settingDiversity:favorite"
        case .popular: return "settingDiversity:popular"
        case .calm: return "settingMoodEnergy:calm"
        case .joyful: return "settingMoodEnergy:fun"
        case .sad: return "settingMoodEnergy:sad"
        case .russian: return "settingLanguage:russian"
        case .foreign: return "settingLanguage:not-russian"
        case .focus: return "activity:work"
        case .workout: return "activity:sport"
        }
    }

    public var v1SettingsPayload: (moodEnergy: String, diversity: String, language: String)? {
        switch self {
        case .defaultWave:
            return nil
        case .energetic:
            return ("active", "default", "any")
        case .calm:
            return ("calm", "default", "any")
        case .joyful:
            return ("fun", "default", "any")
        case .sad:
            return ("sad", "default", "any")
        case .unfamiliar:
            return ("all", "discover", "any")
        case .familiar:
            return ("all", "favorite", "any")
        case .popular:
            return ("all", "popular", "any")
        case .russian:
            return ("all", "default", "russian")
        case .foreign:
            return ("all", "default", "not-russian")
        case .focus:
            return ("calm", "default", "any")
        case .workout:
            return ("active", "default", "any")
        }
    }

    /// Query parameters forwarded to Rotor Station v1 (`GET /rotor/station/{id}/tracks?settings2=true`).
    public var v1QueryItems: [URLQueryItem] {
        switch self {
        case .defaultWave:
            return []
        case .unfamiliar:
            return [URLQueryItem(name: "diversity", value: "discover")]
        case .familiar:
            return [URLQueryItem(name: "diversity", value: "favorite")]
        case .popular:
            return [URLQueryItem(name: "diversity", value: "popular")]
        case .energetic:
            return [URLQueryItem(name: "moodEnergy", value: "energize")]
        case .calm:
            return [URLQueryItem(name: "moodEnergy", value: "calm")]
        case .joyful:
            return [URLQueryItem(name: "moodEnergy", value: "fun")]
        case .sad:
            return [URLQueryItem(name: "moodEnergy", value: "sad")]
        case .russian:
            return [URLQueryItem(name: "language", value: "russian")]
        case .foreign:
            return [URLQueryItem(name: "language", value: "not-russian")]
        case .focus:
            return [URLQueryItem(name: "moodEnergy", value: "calm")]
        case .workout:
            return [URLQueryItem(name: "moodEnergy", value: "energize")]
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
    public let idForFrom: String?
    public let fallbackTrackSeeds: [String]

    public init(
        title: String,
        subtitle: String,
        seeds: [String],
        fallbackStationId: String = "user:onyourwave",
        idForFrom: String? = nil,
        fallbackTrackSeeds: [String] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.seeds = seeds
        self.fallbackStationId = fallbackStationId
        self.idForFrom = idForFrom
        self.fallbackTrackSeeds = fallbackTrackSeeds
    }

    public static let myWaveDefault = YMWaveContext(
        title: "Моя волна",
        subtitle: "Бесконечный персональный поток музыки под ваше настроение",
        seeds: ["user:onyourwave"],
        fallbackStationId: "user:onyourwave"
    )

    public static func forTrack(_ track: YMTrack) -> YMWaveContext {
        let cleanId = track.id.components(separatedBy: ":").first ?? track.id
        return YMWaveContext(
            title: "Волна по треку: \(track.title)",
            subtitle: "Похожее на \(track.artistsString) — \(track.displayTitle)",
            seeds: ["track:\(cleanId)"],
            fallbackStationId: "track:\(cleanId)"
        )
    }

    public static func forPlaylist(_ playlist: YMPlaylist, sampleTrackIds: [String] = []) -> YMWaveContext {
        let primarySeed = "playlist:\(playlist.uid)_\(playlist.kind)"
        let cleanFallbackSeeds = sampleTrackIds.prefix(5).map {
            let cleanId = $0.components(separatedBy: ":").first ?? $0
            return "track:\(cleanId)"
        }
        return YMWaveContext(
            title: "Волна по плейлисту: \(playlist.title)",
            subtitle: "Треки в стиле плейлиста «\(playlist.title)»",
            seeds: [primarySeed],
            fallbackStationId: primarySeed,
            fallbackTrackSeeds: cleanFallbackSeeds
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

    public static func forSavedWave(_ preset: SavedWavePreset) -> YMWaveContext {
        var anchorSeeds: [String] = []
        var seenAnchors = Set<String>()
        for anchor in preset.anchorTracks {
            let cleanId = anchor.id.components(separatedBy: ":").first ?? anchor.id
            guard !cleanId.isEmpty else { continue }
            let seed = "track:\(cleanId)"
            if seenAnchors.insert(seed).inserted {
                anchorSeeds.append(seed)
                if anchorSeeds.count >= 5 { break }
            }
        }

        let modifierSeeds: [String]
        if !anchorSeeds.isEmpty {
            modifierSeeds = preset.baseContextSeeds.filter { seed in
                !seed.isEmpty && seed != "user:onyourwave" && !seed.hasPrefix("track:")
            }
        } else {
            modifierSeeds = preset.baseContextSeeds.filter { !$0.isEmpty }
        }

        var combinedSeeds: [String] = []
        var seenCombined = Set<String>()
        for seed in anchorSeeds + modifierSeeds {
            if seenCombined.insert(seed).inserted {
                combinedSeeds.append(seed)
                if combinedSeeds.count >= 5 { break }
            }
        }
        if combinedSeeds.isEmpty {
            combinedSeeds = ["user:onyourwave"]
        }

        let resolvedFallback: String
        if let firstAnchorSeed = anchorSeeds.first {
            resolvedFallback = firstAnchorSeed
        } else if !preset.baseFallbackStationId.isEmpty {
            resolvedFallback = preset.baseFallbackStationId
        } else {
            resolvedFallback = "user:onyourwave"
        }

        return YMWaveContext(
            title: preset.name,
            subtitle: preset.styleSummary,
            seeds: combinedSeeds,
            fallbackStationId: resolvedFallback,
            fallbackTrackSeeds: anchorSeeds
        )
    }
}

// MARK: - Unified Wave Hub Items & Category Filters

/// Filter tabs for the unified "Поток и настроение" hub in `MyWaveView`.
public enum YMWaveCategoryFilter: String, CaseIterable, Identifiable, Sendable {
    case forYou = "forYou"
    case moods = "moods"
    case genresAndArtists = "genresAndArtists"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forYou: return "Для вас"
        case .moods: return "Настроение и темп"
        case .genresAndArtists: return "Жанры и артисты"
        }
    }

    public var compactTitle: String {
        switch self {
        case .forYou: return "Для вас"
        case .moods: return "Настроение"
        case .genresAndArtists: return "Жанры"
        }
    }
}

/// Unified model combining the base My Wave stream, vibe/tempo modifiers, and personalized Rotor dashboard stations.
public enum YMUnifiedWaveItem: Identifiable, Hashable, Sendable {
    case baseWave
    case vibe(YMWaveVibePreset)
    case station(YMPersonalWaveStation)

    public var id: String {
        switch self {
        case .baseWave:
            return "base:onyourwave"
        case .vibe(let preset):
            return "vibe:\(preset.rawValue)"
        case .station(let station):
            return "station:\(station.id)"
        }
    }

    public var title: String {
        switch self {
        case .baseWave:
            return "Моя волна"
        case .vibe(let preset):
            return preset.title
        case .station(let station):
            return station.title
        }
    }

    public var subtitle: String {
        switch self {
        case .baseWave:
            return "Персональный поток по умолчанию"
        case .vibe(let preset):
            switch preset {
            case .defaultWave: return "Базовый баланс рекомендаций"
            case .energetic: return "Бодрый и драйвовый ритм"
            case .unfamiliar: return "Новые открытия под ваш вкус"
            case .familiar: return "Проверенные любимые треки"
            case .popular: return "Главные хиты и чарты"
            case .calm: return "Спокойная музыка для отдыха"
            case .joyful: return "Лёгкий и позитивный настрой"
            case .sad: return "Глубокое меланхоличное звучание"
            case .russian: return "Треки на русском языке"
            case .foreign: return "Зарубежные исполнители"
            case .focus: return "Фон для работы и концентрации"
            case .workout: return "Энергичный темп для спорта"
            }
        case .station(let station):
            return station.subtitle ?? "Персональная волна «\(station.title)»"
        }
    }

    public var iconName: String {
        switch self {
        case .baseWave:
            return "waveform.path.ecg"
        case .vibe(let preset):
            return preset.iconName
        case .station(let station):
            return station.fallbackIconName
        }
    }

    public var iconUrl: String? {
        switch self {
        case .baseWave, .vibe:
            return nil
        case .station(let station):
            return station.iconUrl
        }
    }

    public var accentHex: String? {
        switch self {
        case .baseWave, .vibe:
            return nil
        case .station(let station):
            return station.accentHex
        }
    }

    public var badgeText: String {
        switch self {
        case .baseWave:
            return "Поток"
        case .vibe(let preset):
            switch preset {
            case .defaultWave: return "Поток"
            case .unfamiliar, .familiar, .popular: return "Новизна"
            case .energetic, .calm, .joyful, .sad: return "Настроение"
            case .russian, .foreign: return "Язык"
            case .focus, .workout: return "Занятие"
            }
        case .station(let station):
            return station.categoryLabel
        }
    }

    /// Builds a deduplicated, curated unified list for a given filter tab.
    public static func items(
        for filter: YMWaveCategoryFilter,
        dashboardStations: [YMPersonalWaveStation]
    ) -> [YMUnifiedWaveItem] {
        switch filter {
        case .forYou:
            let coreVibes: [YMWaveVibePreset] = [.unfamiliar, .familiar, .energetic, .calm]
            let coreVibeSeeds = Set(coreVibes.compactMap(\.seedParameter))
            var result: [YMUnifiedWaveItem] = [.baseWave]
            result.append(contentsOf: coreVibes.map { .vibe($0) })
            for station in dashboardStations where !coreVibeSeeds.contains(station.id) {
                result.append(.station(station))
            }
            return result

        case .moods:
            let allVibes = YMWaveVibePreset.allCases.filter { $0 != .defaultWave }
            let vibeSeeds = Set(allVibes.compactMap(\.seedParameter))
            var result: [YMUnifiedWaveItem] = allVibes.map { .vibe($0) }
            for station in dashboardStations {
                let typeLower = station.type.lowercased()
                if (typeLower == "mood" || typeLower == "activity") && !vibeSeeds.contains(station.id) {
                    result.append(.station(station))
                }
            }
            return result

        case .genresAndArtists:
            let filtered = dashboardStations.filter { station in
                let typeLower = station.type.lowercased()
                return typeLower == "genre" || typeLower == "artist" || typeLower == "epoch" || typeLower == "user"
            }
            let source = filtered.isEmpty ? dashboardStations : filtered
            return source.map { .station($0) }
        }
    }
}
