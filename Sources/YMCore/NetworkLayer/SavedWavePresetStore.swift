import Foundation
import Observation

/// `@MainActor @Observable` store managing user-saved wave presets (`saved_waves.json`)
/// scoped per `ownerUid` with atomic POSIX `0600` persistence.
@Observable
@MainActor
public final class SavedWavePresetStore {
    public static let shared = SavedWavePresetStore()

    public private(set) var presets: [SavedWavePreset] = []

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private var allBuckets: [String: [SavedWavePreset]] = [:]
    @ObservationIgnored private var hasLoadedFromDisk: Bool = false
    @ObservationIgnored private var loadedUid: String? = nil

    public init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.storageURL = appSupport
                .appendingPathComponent("YandexMusicMac", isDirectory: true)
                .appendingPathComponent("saved_waves.json", isDirectory: false)
        }
    }

    // MARK: - Loading & Account Isolation

    public func loadIfNeeded(for ownerUid: String? = nil) {
        let targetUid = ownerUid ?? currentOwnerUid()
        loadFromDiskIfNeeded()

        guard let uid = targetUid, !uid.isEmpty else {
            return
        }
        if loadedUid != uid {
            loadedUid = uid
            syncPresetsForCurrentUid()
        } else if presets.isEmpty && !(allBuckets[uid]?.isEmpty ?? true) {
            syncPresetsForCurrentUid()
        }
    }

    public func resetInMemory() {
        presets = []
        loadedUid = nil
    }

    // MARK: - CRUD

    @discardableResult
    public func createPreset(
        ownerUid: String? = nil,
        name: String,
        icon: SavedWaveIcon,
        accentHex: String,
        baseContextSeeds: [String],
        baseContextTitle: String,
        baseFallbackStationId: String,
        vibe: YMWaveVibePreset,
        anchorTracks: [SavedWaveAnchorTrack],
        excludedTrackIds: [String]
    ) -> SavedWavePreset? {
        let resolvedUid = ownerUid ?? loadedUid ?? currentOwnerUid()
        guard let uid = resolvedUid, !uid.isEmpty else { return nil }

        loadIfNeeded(for: uid)

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Моя волна" : cleanName
        let now = Date()

        let created = SavedWavePreset(
            id: UUID(),
            ownerUid: uid,
            name: finalName,
            icon: icon,
            accentHex: accentHex,
            baseContextSeeds: Self.sanitizedBaseSeeds(baseContextSeeds),
            baseContextTitle: baseContextTitle,
            baseFallbackStationId: baseFallbackStationId,
            vibe: vibe,
            anchorTracks: anchorTracks,
            excludedTrackIds: Array(excludedTrackIds.prefix(30)),
            createdAt: now,
            updatedAt: now
        )

        var bucket = allBuckets[uid] ?? []
        bucket.insert(created, at: 0)
        bucket.sort { $0.updatedAt > $1.updatedAt }
        allBuckets[uid] = bucket
        loadedUid = uid
        syncPresetsForCurrentUid()
        persistToDisk()

        return created
    }

    @discardableResult
    public func overwritePreset(
        id: UUID,
        name: String? = nil,
        icon: SavedWaveIcon? = nil,
        accentHex: String? = nil,
        baseContextSeeds: [String],
        baseContextTitle: String,
        baseFallbackStationId: String,
        vibe: YMWaveVibePreset,
        anchorTracks: [SavedWaveAnchorTrack],
        excludedTrackIds: [String]
    ) -> SavedWavePreset? {
        loadFromDiskIfNeeded()
        guard let (uid, index, existing) = locatePreset(withId: id) else {
            return nil
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (trimmedName?.isEmpty == false) ? trimmedName! : existing.name

        var updated = existing
        updated.name = resolvedName
        if let icon { updated.icon = icon }
        if let accentHex { updated.accentHex = accentHex }
        updated.baseContextSeeds = Self.sanitizedBaseSeeds(baseContextSeeds)
        updated.baseContextTitle = baseContextTitle
        updated.baseFallbackStationId = baseFallbackStationId
        updated.vibe = vibe
        updated.anchorTracks = anchorTracks
        updated.excludedTrackIds = Array(excludedTrackIds.prefix(30))
        updated.updatedAt = Date()

        var bucket = allBuckets[uid] ?? []
        bucket[index] = updated
        bucket.sort { $0.updatedAt > $1.updatedAt }
        allBuckets[uid] = bucket
        if loadedUid == uid {
            syncPresetsForCurrentUid()
        }
        persistToDisk()
        return updated
    }

    public func updateMetadata(
        id: UUID,
        name: String,
        icon: SavedWaveIcon,
        accentHex: String
    ) {
        loadFromDiskIfNeeded()
        guard let (uid, index, existing) = locatePreset(withId: id) else {
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = existing
        updated.name = trimmed.isEmpty ? existing.name : trimmed
        updated.icon = icon
        updated.accentHex = accentHex

        var bucket = allBuckets[uid] ?? []
        bucket[index] = updated
        allBuckets[uid] = bucket
        if loadedUid == uid {
            syncPresetsForCurrentUid()
        }
        persistToDisk()
    }

    public func deletePreset(id: UUID) {
        loadFromDiskIfNeeded()
        guard let (uid, _, _) = locatePreset(withId: id) else {
            return
        }
        var bucket = allBuckets[uid] ?? []
        bucket.removeAll { $0.id == id }
        if bucket.isEmpty {
            allBuckets.removeValue(forKey: uid)
        } else {
            allBuckets[uid] = bucket
        }
        if loadedUid == uid {
            syncPresetsForCurrentUid()
        }
        persistToDisk()
    }

    public func preset(withId id: UUID) -> SavedWavePreset? {
        if let inMemory = presets.first(where: { $0.id == id }) {
            return inMemory
        }
        loadFromDiskIfNeeded()
        return locatePreset(withId: id)?.preset
    }

    // MARK: - Internal Persistence Helpers

    private func currentOwnerUid() -> String? {
        if let uid = AuthService.shared.currentUser?.userId, !uid.isEmpty {
            return uid
        }
        if let saved = KeychainManager.shared.getUserId(), !saved.isEmpty {
            return saved
        }
        return nil
    }

    private func locatePreset(withId id: UUID) -> (uid: String, index: Int, preset: SavedWavePreset)? {
        if let uid = loadedUid,
           let bucket = allBuckets[uid],
           let idx = bucket.firstIndex(where: { $0.id == id }) {
            return (uid, idx, bucket[idx])
        }
        for (uid, bucket) in allBuckets {
            if let idx = bucket.firstIndex(where: { $0.id == id }) {
                return (uid, idx, bucket[idx])
            }
        }
        return nil
    }

    private func syncPresetsForCurrentUid() {
        guard let uid = loadedUid else {
            presets = []
            return
        }
        let bucket = (allBuckets[uid] ?? []).sorted { $0.updatedAt > $1.updatedAt }
        allBuckets[uid] = bucket.isEmpty ? nil : bucket
        presets = bucket
    }

    private func loadFromDiskIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true

        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            allBuckets = [:]
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            guard !data.isEmpty else {
                allBuckets = [:]
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            allBuckets = try decoder.decode([String: [SavedWavePreset]].self, from: data)
        } catch {
            print("[SavedWavePresetStore] Failed to load saved waves (resetting): \(error.localizedDescription)")
            allBuckets = [:]
        }
    }

    private func persistToDisk() {
        let fm = FileManager.default
        do {
            if allBuckets.isEmpty {
                if fm.fileExists(atPath: storageURL.path) {
                    try fm.removeItem(at: storageURL)
                }
                return
            }

            let parentDir = storageURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(
                    at: parentDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
            } else {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: parentDir.path)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allBuckets)
            try data.write(to: storageURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: storageURL.path)

            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = storageURL
            try? mutableURL.setResourceValues(resourceValues)
        } catch {
            print("[SavedWavePresetStore] Failed to persist saved waves: \(error.localizedDescription)")
        }
    }

    private static func sanitizedBaseSeeds(_ seeds: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for seed in seeds where !seed.isEmpty && !seed.hasPrefix("track:") {
            if seen.insert(seed).inserted {
                result.append(seed)
            }
        }
        return result.isEmpty ? ["user:onyourwave"] : result
    }
}
