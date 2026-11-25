import Testing
import Foundation
import CryptoKit
import UniformTypeIdentifiers
@testable import YMCore

@Suite("Offline Mode Crypto, Storage Vault, Resource Loader & Manager Tests")
struct OfflineStorageTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YMOfflineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTestTrack(id: String, title: String = "Offline Test Track", coverUri: String? = "avatars.yandex.net/get-music-content/123/%%") -> YMTrack {
        YMTrack(
            id: id,
            title: title,
            durationMs: 180_000,
            artists: [YMArtist(id: "a1", name: "Test Artist")],
            albums: [YMAlbum(id: "al1", title: "Test Album", coverUri: coverUri)],
            coverUri: coverUri
        )
    }

    @Test("OfflineCrypto streaming encrypt and O(1) random-access range decrypt across chunk boundaries")
    func testStreamingEncryptDecryptAndTamperDetection() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = SymmetricKey(size: .bits256)
        let trackId = "99887766"

        // Construct ~195 KB deterministic source payload spanning 3 x 64 KB chunks
        let totalSize = 65_536 * 2 + 64_123
        var rawBytes = [UInt8](repeating: 0, count: totalSize)
        for i in 0..<totalSize {
            rawBytes[i] = UInt8((i * 31 + (i >> 8)) & 0xFF)
        }
        let sourceData = Data(rawBytes)
        let sourceURL = tempDir.appendingPathComponent("source.bin")
        let encryptedURL = tempDir.appendingPathComponent("99887766.ymo")
        try sourceData.write(to: sourceURL)

        let header = try OfflineCrypto.encryptFileStreaming(
            sourceURL: sourceURL,
            destinationURL: encryptedURL,
            trackId: trackId,
            key: key
        )
        #expect(header.chunkSize == OfflineContainerHeader.defaultChunkSize)
        #expect(header.plaintextSize == UInt64(totalSize))

        // Verify serialized header round-trip and POSIX permissions (0600)
        let attrs = try FileManager.default.attributesOfItem(atPath: encryptedURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        let handle = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? handle.close() }
        let parsedHeader = try OfflineCrypto.readHeader(from: handle)
        #expect(parsedHeader == header)

        func readDecrypted(offset: UInt64, length: Int) throws -> Data {
            var output = Data()
            try OfflineCrypto.decryptRange(
                from: handle,
                header: parsedHeader,
                trackId: trackId,
                key: key,
                offset: offset,
                length: length
            ) { slice in
                output.append(slice)
                return true
            }
            return output
        }

        // 1. 2-byte AVPlayer probe at offset 0
        #expect(try readDecrypted(offset: 0, length: 2) == sourceData.subdata(in: 0..<2))

        // 2. Exact chunk boundary offsets: 65_535, 65_536, 65_537
        for boundary in [65_535, 65_536, 65_537] {
            let slice = try readDecrypted(offset: UInt64(boundary), length: 32)
            #expect(slice == sourceData.subdata(in: boundary..<(boundary + 32)))
        }

        // 3. Cross-chunk slice spanning chunk 0 -> chunk 1 -> chunk 2
        let crossOffset = 65_500
        let crossLength = 65_600
        #expect(
            try readDecrypted(offset: UInt64(crossOffset), length: crossLength)
                == sourceData.subdata(in: crossOffset..<(crossOffset + crossLength))
        )

        // 4. Tail read clamping past EOF
        let tailOffset = totalSize - 500
        #expect(try readDecrypted(offset: UInt64(tailOffset), length: 2000) == sourceData.subdata(in: tailOffset..<totalSize))

        // 5. Full reconstruction
        #expect(try readDecrypted(offset: 0, length: totalSize) == sourceData)

        // 6. Early stop via onChunk returning false
        var stoppedEarlyChunks = 0
        try OfflineCrypto.decryptRange(
            from: handle,
            header: parsedHeader,
            trackId: trackId,
            key: key,
            offset: 0,
            length: totalSize
        ) { _ in
            stoppedEarlyChunks += 1
            return false
        }
        #expect(stoppedEarlyChunks == 1)

        // 7. Corrupted chunk detection (flip 1 byte inside chunk #1 ciphertext)
        try handle.close()
        var tampered = try Data(contentsOf: encryptedURL)
        let flipIndex = Int(OfflineContainerHeader.headerByteSize + header.encodedChunkStride) + 50
        tampered[flipIndex] ^= 0xFF
        try tampered.write(to: encryptedURL)

        let tamperedHandle = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? tamperedHandle.close() }
        var caughtCorruption = false
        do {
            _ = try OfflineCrypto.decryptRange(
                from: tamperedHandle,
                header: parsedHeader,
                trackId: trackId,
                key: key,
                offset: 65_536,
                length: 100
            ) { _ in true }
        } catch let err as OfflineCryptoError {
            if case .corruptedChunk(1) = err {
                caughtCorruption = true
            }
        }
        #expect(caughtCorruption)

        // 8. Invalid header detection
        #expect(throws: OfflineCryptoError.self) {
            _ = try OfflineContainerHeader.parse(from: Data("BAD!".utf8 + Data(repeating: 0, count: 28)))
        }

        // 9. Small data vault encryption round-trip
        let secretPayload = Data("{\"hello\":\"offline\"}".utf8)
        let sealed = try OfflineCrypto.sealSmallData(secretPayload, key: key)
        #expect(sealed != secretPayload)
        #expect(try OfflineCrypto.openSmallData(sealed, key: key) == secretPayload)
    }

    @Test("OfflineStorageStore handles records, cover deduplication, lyrics, orphan cleanup and entitlement")
    func testOfflineStorageStoreOperations() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let audioKey = SymmetricKey(size: .bits256)
        let metaKey = SymmetricKey(size: .bits256)
        let store = OfflineStorageStore(baseDirectory: tempDir, audioKey: audioKey, metaKey: metaKey)

        // Create orphan .tmp file & orphan .ymo file BEFORE first load to verify cleanup
        let audioDir = tempDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let orphanTmp = audioDir.appendingPathComponent("stale.ymo.tmp")
        let orphanAudio = audioDir.appendingPathComponent("999999.ymo")
        try Data("orphan-tmp".utf8).write(to: orphanTmp)
        try Data("orphan-audio".utf8).write(to: orphanAudio)

        let ownerUid = "user-123"
        let sharedCoverUri = "avatars.yandex.net/get-music-content/album77/%%"
        let track1 = makeTestTrack(id: "1001:500", title: "First Track", coverUri: sharedCoverUri)
        let track2 = makeTestTrack(id: "1002", title: "Second Track", coverUri: sharedCoverUri)

        let rawTmp1 = tempDir.appendingPathComponent("dl1.bin")
        let rawTmp2 = tempDir.appendingPathComponent("dl2.bin")
        try Data(repeating: 0xAA, count: 8192).write(to: rawTmp1)
        try Data(repeating: 0xBB, count: 16_384).write(to: rawTmp2)

        let dlInfo = YMDownloadInfo(
            codec: "mp3",
            bitrateInKbps: 320,
            downloadInfoUrl: URL(string: "https://example.com/stream.mp3")!,
            direct: true,
            lossless: false
        )
        let coverBytes = Data("fake-jpeg-cover-payload".utf8)

        let rec1 = try await store.commitDownloadedAudio(
            tempFileURL: rawTmp1,
            track: track1,
            ownerUid: ownerUid,
            downloadInfo: dlInfo,
            coverData: coverBytes,
            rawLRC: "[00:01.00] Hello offline line",
            plainLyrics: nil
        )
        #expect(rec1.id == "1001")
        #expect(rec1.hasSyncedLyrics == true)
        #expect(rec1.hasPlainLyrics == false)
        #expect(rec1.coverHash != nil)

        // Orphans cleaned up upon initial store access
        #expect(!FileManager.default.fileExists(atPath: orphanTmp.path))
        #expect(!FileManager.default.fileExists(atPath: orphanAudio.path))

        // Source temp file removed on commit
        #expect(!FileManager.default.fileExists(atPath: rawTmp1.path))

        // Second track of the same album commits without re-sending coverData (reuses deduplicated cover)
        let hasCoverAlready = await store.hasCover(for: sharedCoverUri)
        #expect(hasCoverAlready)

        let rec2 = try await store.commitDownloadedAudio(
            tempFileURL: rawTmp2,
            track: track2,
            ownerUid: ownerUid,
            downloadInfo: dlInfo,
            coverData: nil,
            rawLRC: nil,
            plainLyrics: "Plain offline lyrics line"
        )
        #expect(rec2.id == "1002")
        #expect(rec2.coverHash == rec1.coverHash)
        #expect(rec2.hasSyncedLyrics == false)
        #expect(rec2.hasPlainLyrics == true)

        // Verify total bytes & queries
        let allRecords = try await store.records(for: ownerUid)
        #expect(allRecords.count == 2)
        #expect(await store.record(for: "1001:999", ownerUid: ownerUid)?.id == "1001")
        #expect(await store.totalUsedBytes(for: ownerUid) == rec1.fileSizeBytes + rec2.fileSizeBytes)

        // Verify local artwork and encrypted lyrics lookup
        #expect(await store.localCoverData(for: sharedCoverUri) == coverBytes)
        #expect(await store.loadLyrics(for: "1001:500")?.lrc == "[00:01.00] Hello offline line")
        #expect(await store.loadLyrics(for: "1002")?.plain == "Plain offline lyrics line")

        // Delete track 1: shared cover must remain because track 2 references it!
        try await store.removeTrack(cleanTrackId: "1001:500", ownerUid: ownerUid)
        #expect(await store.record(for: "1001", ownerUid: ownerUid) == nil)
        #expect(await store.loadLyrics(for: "1001") == nil)
        #expect(await store.localCoverData(for: sharedCoverUri) == coverBytes)
        #expect(await store.hasCover(for: sharedCoverUri) == true)

        // Re-open store from disk to verify encrypted index persistence
        let reloadedStore = OfflineStorageStore(baseDirectory: tempDir, audioKey: audioKey, metaKey: metaKey)
        let reloadedRecords = try await reloadedStore.records(for: ownerUid)
        #expect(reloadedRecords.count == 1)
        #expect(reloadedRecords.first?.id == "1002")

        // Delete last track referencing shared cover: cover file must now be deleted too!
        try await reloadedStore.removeTrack(cleanTrackId: "1002", ownerUid: ownerUid)
        #expect(await reloadedStore.hasCover(for: sharedCoverUri) == false)
        #expect(await reloadedStore.localCoverData(for: sharedCoverUri) == nil)
        #expect(try await reloadedStore.records(for: ownerUid).isEmpty)

        // Entitlement snapshot persistence
        let snapshot = OfflineEntitlementSnapshot(
            userId: ownerUid,
            displayName: "Plus User",
            hasActiveSubscription: true,
            verifiedAt: Date(),
            validUntil: Date().addingTimeInterval(7 * 86_400)
        )
        try await reloadedStore.saveEntitlement(snapshot)
        #expect(await reloadedStore.loadEntitlement(for: ownerUid) == snapshot)
        #expect(await reloadedStore.loadEntitlement(for: "other-user") == nil)
        await reloadedStore.clearEntitlement()
        #expect(await reloadedStore.loadEntitlement(for: ownerUid) == nil)
    }

    @Test("OfflineEntitlementSnapshot enforces 14-day grace ceiling")
    func testEntitlementGracePeriodCeiling() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let farFuture = ISO8601DateFormatter().string(from: now.addingTimeInterval(60 * 86_400))
        let statusLong = YMAccountStatus(
            account: YMAccountInfo(uid: "42", displayName: "Tester"),
            permissions: YMPermissionsInfo(until: farFuture, values: ["play-full-tracks"]),
            plus: YMPlusInfo(hasPlus: true)
        )
        let snapLong = OfflineEntitlementSnapshot(from: statusLong, userId: "42", verifiedAt: now)
        #expect(snapLong.hasActiveSubscription == true)
        #expect(snapLong.validUntil == now.addingTimeInterval(14 * 86_400))

        let soonFutureDate = now.addingTimeInterval(3 * 86_400)
        let soonFuture = ISO8601DateFormatter().string(from: soonFutureDate)
        let statusShort = YMAccountStatus(
            account: YMAccountInfo(uid: "42", displayName: "Tester"),
            permissions: YMPermissionsInfo(until: soonFuture, values: ["play-full-tracks"]),
            plus: YMPlusInfo(hasPlus: true)
        )
        let snapShort = OfflineEntitlementSnapshot(from: statusShort, userId: "42", verifiedAt: now)
        #expect(abs(snapShort.validUntil.timeIntervalSince(soonFutureDate)) < 1.0)
    }

    @Test("OfflineAssetResourceLoaderDelegate maps codecs to accurate UTIs and file extensions")
    func testResourceLoaderUTIsAndAssetConstruction() throws {
        let expectedFlacUTI = UTType(filenameExtension: "flac")?.identifier ?? "org.xiph.flac"
        let expectedAacUTI = UTType(filenameExtension: "aac")?.identifier ?? "public.aac-audio"

        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "flac") == expectedFlacUTI)
        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "flac-mp4") == UTType.mpeg4Audio.identifier)
        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "aac-mp4") == UTType.mpeg4Audio.identifier)
        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "he-aac-mp4") == UTType.mpeg4Audio.identifier)
        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "aac") == expectedAacUTI)
        #expect(OfflineAssetResourceLoaderDelegate.uti(forCodec: "mp3") == UTType.mp3.identifier)

        #expect(OfflineAssetResourceLoaderDelegate.fileExtension(forCodec: "flac") == "flac")
        #expect(OfflineAssetResourceLoaderDelegate.fileExtension(forCodec: "flac-mp4") == "m4a")
        #expect(OfflineAssetResourceLoaderDelegate.fileExtension(forCodec: "aac-mp4") == "m4a")
        #expect(OfflineAssetResourceLoaderDelegate.fileExtension(forCodec: "aac") == "aac")
        #expect(OfflineAssetResourceLoaderDelegate.fileExtension(forCodec: "mp3") == "mp3")

        let dummyURL = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.ymo")
        let key = SymmetricKey(size: .bits256)
        let built = OfflineAssetResourceLoaderDelegate.makeAsset(
            fileURL: dummyURL,
            trackId: "123456",
            codec: "mp3",
            key: key
        )
        #expect(built != nil)
        #expect(built?.asset.url.scheme == OfflineAssetResourceLoaderDelegate.scheme)
        #expect(built?.asset.url.pathExtension == "mp3")
        built?.delegate.invalidate()
    }

    @Test("OfflineDownloadManager normalizes track IDs for isolated O(1) track states")
    @MainActor
    func testOfflineDownloadManagerStateNormalization() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = OfflineStorageStore(
            baseDirectory: tempDir,
            audioKey: SymmetricKey(size: .bits256),
            metaKey: SymmetricKey(size: .bits256)
        )
        let manager = OfflineDownloadManager(store: store)

        let stComposite = manager.state(for: "555111:999")
        let stClean = manager.state(for: "555111")
        #expect(stComposite === stClean)
        #expect(stClean.phase == .notDownloaded)

        stComposite.phase = .downloading(progress: 0.42)
        #expect(manager.state(for: "555111").phase == .downloading(progress: 0.42))
    }

    @Test("OfflineStorageStore isolates track records and removal per ownerUid")
    func testMultiAccountIsolationInOfflineStorageStore() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = OfflineStorageStore(
            baseDirectory: tempDir,
            audioKey: SymmetricKey(size: .bits256),
            metaKey: SymmetricKey(size: .bits256)
        )

        let track = makeTestTrack(id: "777", title: "Shared Track")
        let info = YMDownloadInfo(
            codec: "mp3",
            bitrateInKbps: 320,
            downloadInfoUrl: URL(string: "https://example.com/shared.mp3")!,
            direct: true,
            lossless: false
        )

        let tmpA = tempDir.appendingPathComponent("a.bin")
        let tmpB = tempDir.appendingPathComponent("b.bin")
        try Data(repeating: 0x11, count: 4096).write(to: tmpA)
        try Data(repeating: 0x22, count: 4096).write(to: tmpB)

        let recA = try await store.commitDownloadedAudio(
            tempFileURL: tmpA,
            track: track,
            ownerUid: "user-A",
            downloadInfo: info,
            coverData: Data("cover".utf8),
            rawLRC: "[00:00.00] Hi",
            plainLyrics: nil
        )
        _ = try await store.commitDownloadedAudio(
            tempFileURL: tmpB,
            track: track,
            ownerUid: "user-B",
            downloadInfo: info,
            coverData: nil,
            rawLRC: nil,
            plainLyrics: nil
        )

        try await store.removeAll(for: "user-A")
        #expect(try await store.records(for: "user-A").isEmpty)

        let userBRecords = try await store.records(for: "user-B")
        #expect(userBRecords.count == 1)
        let audioURL = await store.audioFileURL(for: recA)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(await store.hasCover(for: track.effectiveCoverUri ?? "") == true)
    }

    @Test("AudioQualitySettings persists offline preset and limit including 0 unlimited")
    @MainActor
    func testOfflineAudioQualitySettingsPersistence() {
        let defaults = UserDefaults.standard
        let presetKey = "ym_offline_quality_preset"
        let limitKey = "ym_offline_cache_limit_gb"
        let prevPreset = defaults.object(forKey: presetKey)
        let prevLimit = defaults.object(forKey: limitKey)

        defer {
            if let prevPreset { defaults.set(prevPreset, forKey: presetKey) } else { defaults.removeObject(forKey: presetKey) }
            if let prevLimit { defaults.set(prevLimit, forKey: limitKey) } else { defaults.removeObject(forKey: limitKey) }
        }

        defaults.removeObject(forKey: presetKey)
        defaults.removeObject(forKey: limitKey)

        let defaultSettings = AudioQualitySettings()
        #expect(defaultSettings.offlineQualityPreset == .high320)
        #expect(defaultSettings.offlineCacheLimitGB == 5)

        defaultSettings.setOfflineQualityPreset(.lossless)
        defaultSettings.setOfflineCacheLimitGB(0)

        let reloadedSettings = AudioQualitySettings()
        #expect(reloadedSettings.offlineQualityPreset == .lossless)
        #expect(reloadedSettings.offlineCacheLimitGB == 0)

        // Unsupported limit falls back safely to 5 GB
        reloadedSettings.setOfflineCacheLimitGB(999)
        #expect(reloadedSettings.offlineCacheLimitGB == 5)
    }

    @Test("AudioQualitySettings custom offline cache limit parses, clamps, persists, and computes byte quota")
    @MainActor
    func testCustomOfflineCacheLimitSettings() {
        let defaults = UserDefaults.standard
        let presetKey = "ym_offline_cache_limit_gb"
        let customEnabledKey = "ym_offline_cache_custom_enabled"
        let customGBKey = "ym_offline_cache_custom_gb"
        let prevPreset = defaults.object(forKey: presetKey)
        let prevCustomEnabled = defaults.object(forKey: customEnabledKey)
        let prevCustomGB = defaults.object(forKey: customGBKey)

        defer {
            if let prevPreset { defaults.set(prevPreset, forKey: presetKey) } else { defaults.removeObject(forKey: presetKey) }
            if let prevCustomEnabled { defaults.set(prevCustomEnabled, forKey: customEnabledKey) } else { defaults.removeObject(forKey: customEnabledKey) }
            if let prevCustomGB { defaults.set(prevCustomGB, forKey: customGBKey) } else { defaults.removeObject(forKey: customGBKey) }
        }

        defaults.removeObject(forKey: presetKey)
        defaults.removeObject(forKey: customEnabledKey)
        defaults.removeObject(forKey: customGBKey)

        #expect(AudioQualitySettings.parseCustomCacheLimitGB("1,5") == 1.5)
        #expect(AudioQualitySettings.parseCustomCacheLimitGB(" 35 ГБ ") == 35.0)
        #expect(AudioQualitySettings.parseCustomCacheLimitGB("0.01") == 0.1)
        #expect(AudioQualitySettings.parseCustomCacheLimitGB("9999") == 500.0)
        #expect(AudioQualitySettings.parseCustomCacheLimitGB("-5") == nil)
        #expect(AudioQualitySettings.parseCustomCacheLimitGB("abc") == nil)

        let settings = AudioQualitySettings()
        #expect(settings.offlineCacheCustomLimitEnabled == false)
        #expect(settings.effectiveOfflineCacheLimitBytes == Int64(5) * 1_073_741_824)
        #expect(settings.effectiveOfflineCacheLimitDisplay == "5 ГБ")

        settings.setOfflineCacheCustomLimitGB(2.5)
        settings.setOfflineCacheCustomLimitEnabled(true)

        let reloaded = AudioQualitySettings()
        #expect(reloaded.offlineCacheCustomLimitEnabled == true)
        #expect(reloaded.offlineCacheCustomLimitGB == 2.5)
        #expect(reloaded.effectiveOfflineCacheLimitDisplay == "2.5 ГБ")
        #expect(reloaded.effectiveOfflineCacheLimitBytes == Int64((2.5 * 1_073_741_824.0).rounded()))

        reloaded.setOfflineCacheLimitGB(0)
        reloaded.setOfflineCacheCustomLimitEnabled(false)
        #expect(reloaded.effectiveOfflineCacheLimitBytes == 0)
        #expect(reloaded.effectiveOfflineCacheLimitDisplay == "Без лимита")
    }
}
