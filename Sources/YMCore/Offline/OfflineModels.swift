import Foundation
import Observation

/// Helper for normalizing Yandex Music composite track IDs (`"12345:6789"`) to clean numeric track IDs (`"12345"`).
public enum OfflineTrackID: Sendable {
    public static func clean(_ trackId: String) -> String {
        if let colon = trackId.firstIndex(of: ":") {
            let prefix = trackId[..<colon]
            return prefix.isEmpty ? trackId : String(prefix)
        }
        return trackId
    }
}

/// Persistent metadata record for an encrypted offline audio track in `index.vault`.
public struct OfflineTrackRecord: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let ownerUid: String
    public let track: YMTrack
    public let audioFileName: String
    public let codec: String
    public let bitrateInKbps: Int
    public let isLossless: Bool
    public let fileSizeBytes: Int64
    public let coverHash: String?
    public let hasSyncedLyrics: Bool
    public let hasPlainLyrics: Bool
    public let downloadedAt: Date

    public init(
        id: String,
        ownerUid: String,
        track: YMTrack,
        audioFileName: String,
        codec: String,
        bitrateInKbps: Int,
        isLossless: Bool,
        fileSizeBytes: Int64,
        coverHash: String? = nil,
        hasSyncedLyrics: Bool = false,
        hasPlainLyrics: Bool = false,
        downloadedAt: Date = Date()
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.track = track
        self.audioFileName = audioFileName
        self.codec = codec
        self.bitrateInKbps = bitrateInKbps
        self.isLossless = isLossless
        self.fileSizeBytes = fileSizeBytes
        self.coverHash = coverHash
        self.hasSyncedLyrics = hasSyncedLyrics
        self.hasPlainLyrics = hasPlainLyrics
        self.downloadedAt = downloadedAt
    }
}

/// Encrypted offline lyrics envelope stored per track in `lyrics/{cleanId}.lyc`.
public struct OfflineLyricsEnvelope: Codable, Sendable, Equatable {
    public let lrc: String?
    public let plain: String?

    public init(lrc: String?, plain: String?) {
        self.lrc = lrc
        self.plain = plain
    }
}

/// Encrypted snapshot of Yandex Plus offline entitlement validity (max 14 days offline grace).
public struct OfflineEntitlementSnapshot: Codable, Sendable, Equatable {
    public let userId: String
    public let displayName: String
    public let hasActiveSubscription: Bool
    public let verifiedAt: Date
    public let validUntil: Date

    public init(
        userId: String,
        displayName: String,
        hasActiveSubscription: Bool,
        verifiedAt: Date,
        validUntil: Date
    ) {
        self.userId = userId
        self.displayName = displayName
        self.hasActiveSubscription = hasActiveSubscription
        self.verifiedAt = verifiedAt
        self.validUntil = validUntil
    }

    public init(from status: YMAccountStatus, userId: String, verifiedAt: Date = Date()) {
        let capDate = verifiedAt.addingTimeInterval(14 * 86_400)
        let permissionsUntil = status.permissions?.until.flatMap(YMAccountStatus.parseDate)
        let resolvedUntil = min(permissionsUntil ?? capDate, capDate)
        self.init(
            userId: userId,
            displayName: status.displayName,
            hasActiveSubscription: status.hasActiveSubscription,
            verifiedAt: verifiedAt,
            validUntil: resolvedUntil
        )
    }
}

/// Download & encryption lifecycle phase for an individual track.
public enum TrackOfflinePhase: Equatable, Sendable {
    case notDownloaded
    case queued
    case downloading(progress: Double)
    case encrypting
    case downloaded
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .queued, .downloading, .encrypting:
            return true
        default:
            return false
        }
    }

    public var isDownloaded: Bool {
        if case .downloaded = self {
            return true
        }
        return false
    }
}

/// Isolated per-track `@Observable` state providing O(1) SwiftUI updates without invalidating rows or lists.
@Observable
@MainActor
public final class TrackOfflineState {
    public var phase: TrackOfflinePhase

    public init(phase: TrackOfflinePhase = .notDownloaded) {
        self.phase = phase
    }
}
