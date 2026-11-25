import Foundation
import CryptoKit

/// Actor managing the encrypted offline storage vault (`~/Library/Application Support/YandexMusicMac/OfflineCache/`).
/// Guarantees atomic metadata persistence, album-deduplicated artwork, encrypted lyrics,
/// strict POSIX permissions (`0700`/`0600`), and orphan file cleanup on initialization.
public actor OfflineStorageStore {
    public static let shared = OfflineStorageStore()

    private let baseDirectory: URL
    private let audioDirectory: URL
    private let coversDirectory: URL
    private let lyricsDirectory: URL
    private let indexVaultURL: URL
    private let entitlementVaultURL: URL

    private let audioKey: SymmetricKey
    private let metaKey: SymmetricKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var records: [OfflineTrackRecord] = []
    private var isLoaded: Bool = false

    public init(
        baseDirectory: URL? = nil,
        audioKey: SymmetricKey = OfflineCrypto.audioKey,
        metaKey: SymmetricKey = OfflineCrypto.metaKey
    ) {
        let resolvedBase: URL
        if let baseDirectory {
            resolvedBase = baseDirectory
        } else {
            let fm = FileManager.default
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            resolvedBase = appSupport
                .appendingPathComponent("YandexMusicMac", isDirectory: true)
                .appendingPathComponent("OfflineCache", isDirectory: true)
        }

        self.baseDirectory = resolvedBase
        self.audioDirectory = resolvedBase.appendingPathComponent("audio", isDirectory: true)
        self.coversDirectory = resolvedBase.appendingPathComponent("covers", isDirectory: true)
        self.lyricsDirectory = resolvedBase.appendingPathComponent("lyrics", isDirectory: true)
        self.indexVaultURL = resolvedBase.appendingPathComponent("index.vault", isDirectory: false)
        self.entitlementVaultURL = resolvedBase.appendingPathComponent("entitlement.vault", isDirectory: false)
        self.audioKey = audioKey
        self.metaKey = metaKey
    }

    // MARK: - Queries

    public func records(for ownerUid: String) throws -> [OfflineTrackRecord] {
        try ensureLoaded()
        return records
            .filter { $0.ownerUid == ownerUid }
            .sorted {
                if $0.downloadedAt != $1.downloadedAt {
                    return $0.downloadedAt > $1.downloadedAt
                }
                return $0.id < $1.id
            }
    }

    public func record(for trackId: String, ownerUid: String) -> OfflineTrackRecord? {
        guard (try? ensureLoaded()) != nil else { return nil }
        let cleanId = OfflineTrackID.clean(trackId)
        return records.first { $0.id == cleanId && $0.ownerUid == ownerUid }
    }

    public func audioFileURL(for record: OfflineTrackRecord) -> URL {
        audioDirectory.appendingPathComponent(record.audioFileName, isDirectory: false)
    }

    public func totalUsedBytes(for ownerUid: String?) -> Int64 {
        guard (try? ensureLoaded()) != nil else { return 0 }
        let filtered = ownerUid.map { uid in records.filter { $0.ownerUid == uid } } ?? records
        return filtered.reduce(into: Int64(0)) { sum, item in
            sum += item.fileSizeBytes
        }
    }

    public func hasCover(for coverUri: String) -> Bool {
        guard !coverUri.isEmpty else { return false }
        let hash = Self.coverHash(for: coverUri)
        let coverURL = coversDirectory.appendingPathComponent("\(hash).img", isDirectory: false)
        return FileManager.default.fileExists(atPath: coverURL.path)
    }

    public func localCoverData(for coverUri: String) -> Data? {
        guard !coverUri.isEmpty else { return nil }
        let hash = Self.coverHash(for: coverUri)
        let coverURL = coversDirectory.appendingPathComponent("\(hash).img", isDirectory: false)
        guard FileManager.default.fileExists(atPath: coverURL.path) else {
            return nil
        }
        return try? Data(contentsOf: coverURL)
    }

    public func loadLyrics(for trackId: String) -> (lrc: String?, plain: String?)? {
        let cleanId = OfflineTrackID.clean(trackId)
        let lyricsURL = lyricsDirectory.appendingPathComponent("\(cleanId).lyc", isDirectory: false)
        guard FileManager.default.fileExists(atPath: lyricsURL.path),
              let sealedData = try? Data(contentsOf: lyricsURL),
              let plainData = try? OfflineCrypto.openSmallData(sealedData, key: metaKey),
              let envelope = try? decoder.decode(OfflineLyricsEnvelope.self, from: plainData) else {
            return nil
        }
        return (lrc: envelope.lrc, plain: envelope.plain)
    }

    // MARK: - Commits & Removals

    @discardableResult
    public func commitDownloadedAudio(
        tempFileURL: URL,
        track: YMTrack,
        ownerUid: String,
        downloadInfo: YMDownloadInfo,
        coverData: Data? = nil,
        rawLRC: String? = nil,
        plainLyrics: String? = nil
    ) throws -> OfflineTrackRecord {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempFileURL) }

        try ensureLoaded()

        let cleanId = OfflineTrackID.clean(track.id)
        let audioFileName = "\(cleanId).ymo"
        let audioDestURL = audioDirectory.appendingPathComponent(audioFileName, isDirectory: false)

        let header = try OfflineCrypto.encryptFileStreaming(
            sourceURL: tempFileURL,
            destinationURL: audioDestURL,
            trackId: cleanId,
            key: audioKey
        )

        let encryptedSize: Int64
        if let attrs = try? fm.attributesOfItem(atPath: audioDestURL.path),
           let diskSize = attrs[.size] as? NSNumber {
            encryptedSize = diskSize.int64Value
        } else {
            encryptedSize = Int64(header.plaintextSize)
        }

        var resolvedCoverHash: String? = nil
        if let coverUri = track.effectiveCoverUri, !coverUri.isEmpty {
            let hash = Self.coverHash(for: coverUri)
            let coverURL = coversDirectory.appendingPathComponent("\(hash).img", isDirectory: false)
            if !fm.fileExists(atPath: coverURL.path), let coverData, !coverData.isEmpty {
                try writeProtectedFile(coverData, to: coverURL)
            }
            if fm.fileExists(atPath: coverURL.path) {
                resolvedCoverHash = hash
            }
        }

        let cleanRawLRC = (rawLRC?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawLRC : nil
        let cleanPlainLyrics = (plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? plainLyrics : nil
        let lyricsURL = lyricsDirectory.appendingPathComponent("\(cleanId).lyc", isDirectory: false)

        if cleanRawLRC != nil || cleanPlainLyrics != nil {
            let envelope = OfflineLyricsEnvelope(lrc: cleanRawLRC, plain: cleanPlainLyrics)
            let jsonData = try encoder.encode(envelope)
            let sealed = try OfflineCrypto.sealSmallData(jsonData, key: metaKey)
            try writeProtectedFile(sealed, to: lyricsURL)
        } else if fm.fileExists(atPath: lyricsURL.path) {
            try? fm.removeItem(at: lyricsURL)
        }

        let newRecord = OfflineTrackRecord(
            id: cleanId,
            ownerUid: ownerUid,
            track: track,
            audioFileName: audioFileName,
            codec: downloadInfo.codec,
            bitrateInKbps: downloadInfo.bitrateInKbps,
            isLossless: downloadInfo.isLossless,
            fileSizeBytes: encryptedSize,
            coverHash: resolvedCoverHash,
            hasSyncedLyrics: cleanRawLRC != nil,
            hasPlainLyrics: cleanPlainLyrics != nil,
            downloadedAt: Date()
        )

        records.removeAll { $0.id == cleanId && $0.ownerUid == ownerUid }
        records.append(newRecord)
        try persistIndex()

        return newRecord
    }

    public func removeTrack(cleanTrackId: String, ownerUid: String) throws {
        try ensureLoaded()
        let cleanId = OfflineTrackID.clean(cleanTrackId)
        guard let target = records.first(where: { $0.id == cleanId && $0.ownerUid == ownerUid }) else {
            return
        }

        records.removeAll { $0.id == cleanId && $0.ownerUid == ownerUid }
        try persistIndex()

        let fm = FileManager.default

        if !records.contains(where: { $0.audioFileName == target.audioFileName }) {
            let audioURL = audioDirectory.appendingPathComponent(target.audioFileName, isDirectory: false)
            if fm.fileExists(atPath: audioURL.path) {
                try? fm.removeItem(at: audioURL)
            }
        }

        if !records.contains(where: { $0.id == cleanId }) {
            let lyricsURL = lyricsDirectory.appendingPathComponent("\(cleanId).lyc", isDirectory: false)
            if fm.fileExists(atPath: lyricsURL.path) {
                try? fm.removeItem(at: lyricsURL)
            }
        }

        if let coverHash = target.coverHash,
           !records.contains(where: { $0.coverHash == coverHash }) {
            let coverURL = coversDirectory.appendingPathComponent("\(coverHash).img", isDirectory: false)
            if fm.fileExists(atPath: coverURL.path) {
                try? fm.removeItem(at: coverURL)
            }
        }
    }

    public func removeAll(for ownerUid: String?) throws {
        try ensureLoaded()

        if let ownerUid {
            records.removeAll { $0.ownerUid == ownerUid }
        } else {
            records.removeAll()
        }
        try persistIndex()
        cleanupOrphanFiles()
    }

    // MARK: - Entitlement Snapshot Vault

    public func saveEntitlement(_ snapshot: OfflineEntitlementSnapshot) throws {
        try ensureLoaded()
        let json = try encoder.encode(snapshot)
        let sealed = try OfflineCrypto.sealSmallData(json, key: metaKey)
        try writeProtectedFile(sealed, to: entitlementVaultURL)
    }

    public func loadEntitlement(for userId: String) -> OfflineEntitlementSnapshot? {
        guard FileManager.default.fileExists(atPath: entitlementVaultURL.path),
              let sealed = try? Data(contentsOf: entitlementVaultURL),
              let plain = try? OfflineCrypto.openSmallData(sealed, key: metaKey),
              let snapshot = try? decoder.decode(OfflineEntitlementSnapshot.self, from: plain),
              snapshot.userId == userId else {
            return nil
        }
        return snapshot
    }

    public func clearEntitlement() {
        let fm = FileManager.default
        if fm.fileExists(atPath: entitlementVaultURL.path) {
            try? fm.removeItem(at: entitlementVaultURL)
        }
    }

    // MARK: - Helpers & Persistence

    public nonisolated static func coverHash(for coverUri: String) -> String {
        let digest = SHA256.hash(data: Data(coverUri.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    private func ensureLoaded() throws {
        guard !isLoaded else { return }

        try ensureProtectedDirectory(baseDirectory)
        try ensureProtectedDirectory(audioDirectory)
        try ensureProtectedDirectory(coversDirectory)
        try ensureProtectedDirectory(lyricsDirectory)

        let fm = FileManager.default
        if fm.fileExists(atPath: indexVaultURL.path) {
            do {
                let sealed = try Data(contentsOf: indexVaultURL)
                if !sealed.isEmpty {
                    let plain = try OfflineCrypto.openSmallData(sealed, key: metaKey)
                    records = try decoder.decode([OfflineTrackRecord].self, from: plain)
                }
            } catch {
                print("[OfflineStorageStore] Failed to decrypt offline index (resetting): \(error.localizedDescription)")
                records = []
            }
        }

        // Remove stale index records whose encrypted audio files are missing on disk
        let beforeCount = records.count
        records.removeAll { record in
            let url = audioDirectory.appendingPathComponent(record.audioFileName, isDirectory: false)
            return !fm.fileExists(atPath: url.path)
        }

        isLoaded = true

        if records.count != beforeCount {
            try? persistIndex()
        }
        cleanupOrphanFiles()
    }

    private func persistIndex() throws {
        let fm = FileManager.default
        if records.isEmpty {
            if fm.fileExists(atPath: indexVaultURL.path) {
                try fm.removeItem(at: indexVaultURL)
            }
            return
        }
        let plain = try encoder.encode(records)
        let sealed = try OfflineCrypto.sealSmallData(plain, key: metaKey)
        try writeProtectedFile(sealed, to: indexVaultURL)
    }

    private func cleanupOrphanFiles() {
        let fm = FileManager.default
        let validAudioNames = Set(records.map(\.audioFileName))
        let validCoverNames = Set(records.compactMap(\.coverHash).map { "\($0).img" })
        let validLyricsNames = Set(records.map { "\($0.id).lyc" })

        for dir in [baseDirectory, audioDirectory, coversDirectory, lyricsDirectory] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items {
                let name = item.lastPathComponent
                if item.pathExtension.lowercased() == "tmp" {
                    try? fm.removeItem(at: item)
                    continue
                }
                if dir == audioDirectory && !validAudioNames.contains(name) {
                    try? fm.removeItem(at: item)
                } else if dir == coversDirectory && !validCoverNames.contains(name) {
                    try? fm.removeItem(at: item)
                } else if dir == lyricsDirectory && !validLyricsNames.contains(name) {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    private func ensureProtectedDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }

    private func writeProtectedFile(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try ensureProtectedDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}
