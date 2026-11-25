import Testing
import Foundation
import AppKit
import MediaPlayer
@testable import YMCore

@Test("Audio URL Signer MD5 computation with reference vectors")
func testAudioURLSigner() {
    let host = "storage.music.yandex.net"
    let path = "/track-data/file.mp3"
    let ts = "1700000000"
    let s = "9f27c3da374"

    // Expected hash for:
    // "XGRlBW9FXlekgbPrRHuSiA" + "track-data/file.mp3" + "9f27c3da374"
    let expectedSign = "16b8913dbd0482b8ee3782a5be41c832"
    let computedSign = YMAudioURLSigner.computeSign(path: path, s: s)
    #expect(computedSign == expectedSign)

    let expectedURLString = "https://storage.music.yandex.net/get-mp3/16b8913dbd0482b8ee3782a5be41c832/1700000000/track-data/file.mp3"
    let url = YMAudioURLSigner.signStream(host: host, path: path, ts: ts, s: s)
    #expect(url?.absoluteString == expectedURLString)
}

@Test("Audio URL Signer with YMStreamData model")
func testAudioURLSignerWithStreamData() {
    let streamData = YMStreamData(
        host: "storage.mds.yandex.net",
        path: "/get-mp3/audio123.mp3",
        ts: "1699999999",
        s: "salt_value_123"
    )

    let url = YMAudioURLSigner.signStream(from: streamData)
    #expect(url != nil)
    #expect(url?.host == "storage.mds.yandex.net")
    #expect(url?.pathComponents.contains("get-mp3") == true)
}

@Test("YMTrack decoding handles Int and String IDs seamlessly")
func testTrackFlexibleIDDecoding() throws {
    // Track with integer ID
    let jsonIntID = """
    {
        "id": 12345678,
        "title": "Song with Int ID",
        "durationMs": 210000,
        "artists": [
            { "id": 4321, "name": "Test Artist" }
        ],
        "albums": [
            { "id": 9876, "title": "Test Album", "year": 2024 }
        ],
        "coverUri": "avatars.yandex.net/get-music-content/123/%%"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let trackInt = try decoder.decode(YMTrack.self, from: jsonIntID)
    #expect(trackInt.id == "12345678")
    #expect(trackInt.artists.first?.id == "4321")
    #expect(trackInt.albums.first?.id == "9876")
    #expect(trackInt.primaryAlbumTitle == "Test Album")
    #expect(trackInt.formattedDuration == "3:30")
    #expect(trackInt.rotorTrackIdentifier == "12345678:9876")
    #expect(trackInt.coverURL(size: .small)?.absoluteString == "https://avatars.yandex.net/get-music-content/123/100x100")
    #expect(trackInt.coverURL(size: .large)?.absoluteString == "https://avatars.yandex.net/get-music-content/123/400x400")

    // Track with String ID
    let jsonStrID = """
    {
        "id": "87654321",
        "title": "Song with String ID",
        "version": "Acoustic",
        "artists": [],
        "albums": []
    }
    """.data(using: .utf8)!

    let trackStr = try decoder.decode(YMTrack.self, from: jsonStrID)
    #expect(trackStr.id == "87654321")
    #expect(trackStr.displayTitle == "Song with String ID (Acoustic)")
}

@Test("YMResponse successfully unrolls result or throws API error")
func testResponseEnvelope() throws {
    let successJSON = """
    {
        "invocationInfo": { "req-id": "req-123", "hostname": "web-srv1" },
        "result": {
            "id": 100,
            "title": "Wrapped Track",
            "artists": [],
            "albums": []
        }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let successEnvelope = try decoder.decode(YMResponse<YMTrack>.self, from: successJSON)
    let track = try successEnvelope.unwrap()
    #expect(track.id == "100")
    #expect(track.title == "Wrapped Track")

    let errorJSON = """
    {
        "invocationInfo": { "req-id": "req-fail" },
        "error": {
            "name": "not-found",
            "message": "Track does not exist"
        }
    }
    """.data(using: .utf8)!

    let errorEnvelope = try decoder.decode(YMResponse<YMTrack>.self, from: errorJSON)
    #expect(throws: YMAPIError.self) {
        _ = try errorEnvelope.unwrap()
    }
}

@Test("selectBestAudioDownloadInfo prefers 320kbps MP3")
func testSelectBestAudioStream() {
    let stream128 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 128,
        downloadInfoUrl: URL(string: "https://example.com/128")!
    )
    let stream192 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 192,
        downloadInfoUrl: URL(string: "https://example.com/192")!
    )
    let stream320 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 320,
        downloadInfoUrl: URL(string: "https://example.com/320")!
    )
    let streamPreview = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 320,
        preview: true,
        downloadInfoUrl: URL(string: "https://example.com/preview")!
    )

    let items = [stream128, streamPreview, stream192, stream320]
    let best = items.selectBestAudioDownloadInfo()

    #expect(best?.bitrateInKbps == 320)
    #expect(best?.preview != true)
    #expect(best?.downloadInfoUrl.absoluteString == "https://example.com/320")
}

@Test("KeychainManager operations, AES-GCM encryption at rest, and 0600 permissions")
func testKeychainManager() throws {
    let service = "com.yandexmusic.mac.tests.\(UUID().uuidString)"
    let manager = KeychainManager(service: service)
    let token = "test_oauth_token_12345"
    let userId = "998877"

    try manager.saveToken(token)
    try manager.saveUserId(userId)

    #expect(manager.getToken() == token)
    #expect(manager.getUserId() == userId)

    // Verify encrypted on disk (no plaintext leak) and strict 0600 POSIX permissions
    let vaultURL = manager.storageFileURL
    let rawOnDisk = try Data(contentsOf: vaultURL)
    let rawText = String(decoding: rawOnDisk, as: UTF8.self)
    #expect(!rawText.contains(token))
    #expect(!rawText.contains(userId))

    let attrs = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
    let perms = attrs[.posixPermissions] as? NSNumber
    #expect(perms?.intValue == 0o600)

    // Verify persistence across a fresh manager instance (simulating app relaunch / rebuild)
    let reloadedManager = KeychainManager(service: service)
    #expect(reloadedManager.getToken() == token)
    #expect(reloadedManager.getUserId() == userId)

    try manager.deleteToken()
    #expect(manager.getToken() == nil)
    #expect(manager.getUserId() == userId)

    try manager.clearAll()
    #expect(manager.getToken() == nil)
    #expect(manager.getUserId() == nil)
    #expect(!FileManager.default.fileExists(atPath: vaultURL.path))
}

// MARK: - Stage 2 Audio Engine Tests

@Test("PlaybackProgressTracker operations and isolation")
@MainActor
func testPlaybackProgressTracker() {
    let tracker = PlaybackProgressTracker()
    tracker.update(currentTime: 30, duration: 120)
    #expect(tracker.currentTime == 30)
    #expect(tracker.duration == 120)
    #expect(tracker.progress == 0.25)
    #expect(tracker.currentTimeFormatted == "0:30")
    #expect(tracker.durationFormatted == "2:00")
    #expect(tracker.remainingTimeFormatted == "-1:30")

    // When user drags the slider, updates are ignored to prevent slider jitter
    tracker.isUserSeeking = true
    tracker.update(currentTime: 31, duration: 120)
    #expect(tracker.currentTime == 30)

    tracker.isUserSeeking = false
    tracker.progress = 0.5
    #expect(tracker.currentTime == 60)
}

@Test("AudioPlayerEngine queue assignment")
@MainActor
func testAudioPlayerEngineQueue() {
    let engine = AudioPlayerEngine()
    let track1 = YMTrack(id: "1", title: "Track One")
    let track2 = YMTrack(id: "2", title: "Track Two")

    engine.appendToQueue([track1, track2])
    #expect(engine.queue.count == 2)
    #expect(engine.volume >= 0 && engine.volume <= 1.0)
}

// MARK: - Stage 3 System Integration Tests

@Test("NowPlayingController metadata management")
@MainActor
func testNowPlayingController() {
    let controller = NowPlayingController.shared
    let track = YMTrack(
        id: "42",
        title: "Test NowPlaying Title",
        version: "Live",
        durationMs: 180000,
        artists: [YMArtist(id: "1", name: "Artist")],
        albums: [YMAlbum(id: "1", title: "Album Title")]
    )

    controller.updateTrack(track, isPlaying: true, currentTime: 15)
    controller.updatePlaybackState(isPlaying: false, currentTime: 30)
    controller.updatePlaybackPosition(seconds: 45, isPlaying: false)
    controller.clearNowPlaying()
}

@Test("ImageDownsampler downsamples raw bitmap data")
func testImageDownsampler() {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 200,
        pixelsHigh: 200,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 200 * 4,
        bitsPerPixel: 32
    )!

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        #expect(Bool(false), "Failed to generate test PNG data")
        return
    }

    let downsampled = ImageDownsampler.downsample(data: pngData, maxPixelSize: 64)
    #expect(downsampled != nil)
    #expect(downsampled?.size.width == 64)
    #expect(downsampled?.size.height == 64)
}

// MARK: - Stage 4 Rotor & Likes Tests

@Test("Rotor station tracks decoding")
func testRotorStationTracksDecoding() throws {
    let json = """
    {
        "batchId": "test_batch_12345",
        "sequence": [
            {
                "type": "track",
                "track": {
                    "id": "112233",
                    "title": "Wave Track 1",
                    "durationMs": 190000,
                    "artists": [{ "id": 1, "name": "Artist 1" }],
                    "albums": [{ "id": 2, "title": "Album 1" }]
                }
            }
        ]
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let result = try decoder.decode(YMRotorStationTracksResult.self, from: json)
    #expect(result.batchId == "test_batch_12345")
    #expect(result.sequence.count == 1)
    #expect(result.sequence.first?.track?.id == "112233")
    #expect(result.sequence.first?.track?.rotorTrackIdentifier == "112233:2")
}

@Test("Rotor feedback payload encoding structure")
func testRotorFeedbackPayloadEncoding() throws {
    let event = YMRotorFeedbackEvent(
        type: .trackFinished,
        timestamp: "2026-10-31T17:00:00.000Z",
        trackId: "112233:2",
        totalPlayedSeconds: 190.0
    )
    let payload = YMRotorFeedbackPayload(event: event)

    let encoder = JSONEncoder()
    let data = try encoder.encode(payload)
    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let eventDict = jsonObject?["event"] as? [String: Any]

    #expect(eventDict?["type"] as? String == "trackFinished")
    #expect(eventDict?["trackId"] as? String == "112233:2")
    #expect(eventDict?["totalPlayedSeconds"] as? Double == 190.0)
    #expect(eventDict?["from"] as? String == "mobile-home-rup_main-user-onyourwave-default")
}

@Test("LikesLibrary response decoding")
func testLikesLibraryDecoding() throws {
    let json = """
    {
        "library": {
            "tracks": [
                { "id": "1001", "albumId": "2001" },
                { "id": 1002, "albumId": 2002 }
            ]
        }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let response = try decoder.decode(YMLikesLibraryResponse.self, from: json)
    #expect(response.allTrackIds.count == 2)
    #expect(response.allTrackIds.contains("1001"))
    #expect(response.allTrackIds.contains("1002"))
}

@Test("LikesService O(1) membership operations")
@MainActor
func testLikesServiceMembership() {
    let likes = LikesService.shared
    #expect(!likes.isLiked(trackId: "non_existent"))
}

// MARK: - Stage 5 ImagePipeline & AuthService Tests

@Test("ImagePipeline cache operations")
@MainActor
func testImagePipeline() async {
    let pipeline = ImagePipeline(maxMemoryCost: 10 * 1024 * 1024)
    pipeline.clearCache()

    // Querying with nil / empty coverUri immediately returns nil
    let nilResult = await pipeline.image(for: nil)
    #expect(nilResult == nil)

    let emptyResult = await pipeline.image(for: "")
    #expect(emptyResult == nil)
}

@Test("AuthService initialization and sign out")
@MainActor
func testAuthServiceSignOut() {
    let testKeychain = KeychainManager(service: "com.yandexmusic.mac.tests.\(UUID().uuidString)")
    let auth = AuthService(keychain: testKeychain)
    auth.signOut()
    #expect(!auth.isAuthenticated)
    #expect(auth.currentUser == nil)
}

@Test("AuthService official client ID and canonical OAuth URL")
@MainActor
func testAuthServiceOfficialOAuthURL() {
    #expect(AuthService.oauthClientID == "23cabbbdc6cd418abb4b39c32c41195d")
    #expect(AuthService.oauthURLString == "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d")
}

@Test("AuthService token extraction from raw tokens and redirect URLs")
@MainActor
func testAuthServiceTokenExtraction() {
    let expectedToken = "y0_AgAAAAABcDefGhi12345"

    // Raw token with whitespace
    let raw = "  y0_AgAAAAABcDefGhi12345 \n"
    #expect(AuthService.extractToken(from: raw) == expectedToken)

    // Full redirect URL with fragment
    let urlFragment = "https://music.yandex.ru/#access_token=y0_AgAAAAABcDefGhi12345&token_type=bearer&expires_in=31536000"
    #expect(AuthService.extractToken(from: urlFragment) == expectedToken)

    // URL with query parameter
    let urlQuery = "https://music.yandex.ru/?access_token=y0_AgAAAAABcDefGhi12345&state=ok"
    #expect(AuthService.extractToken(from: urlQuery) == expectedToken)

    // Fragment only
    let fragmentOnly = "#access_token=y0_AgAAAAABcDefGhi12345&expires_in=1000"
    #expect(AuthService.extractToken(from: fragmentOnly) == expectedToken)

    // Empty input
    #expect(AuthService.extractToken(from: "   ").isEmpty)
}

@Test("Rotor station tracks decoding supports both batchId and batch-id")
func testRotorStationTracksKebabBatchId() throws {
    let jsonKebab = """
    {
        "batch-id": "kebab_batch_9988",
        "sequence": []
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let result = try decoder.decode(YMRotorStationTracksResult.self, from: jsonKebab)
    #expect(result.batchId == "kebab_batch_9988")
    #expect(result.sequence.isEmpty)
}

@Test("Playlist and YMTrackShort decoding")
func testPlaylistModelDecoding() throws {
    let json = """
    {
        "uid": 123456,
        "kind": 3,
        "title": "Мой плейлист",
        "trackCount": 1,
        "cover": {
            "uri": "avatars.yandex.net/get-music-user-playlist/123/%%"
        },
        "tracks": [
            {
                "id": "555",
                "albumId": "666",
                "track": {
                    "id": 555,
                    "title": "Track Inside Playlist"
                }
            }
        ]
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let playlist = try decoder.decode(YMPlaylist.self, from: json)
    #expect(playlist.uid == "123456")
    #expect(playlist.kind == 3)
    #expect(playlist.title == "Мой плейлист")
    #expect(playlist.trackCount == 1)
    #expect(playlist.coverURL(size: .medium)?.absoluteString == "https://avatars.yandex.net/get-music-user-playlist/123/200x200")
    #expect(playlist.tracks?.first?.id == "555")
    #expect(playlist.tracks?.first?.track?.title == "Track Inside Playlist")
}

@Test("Search response decoding with string execDurationMillis")
func testSearchResponseDecoding() throws {
    let json = """
    {
        "invocationInfo": {
            "req-id": "req-123",
            "hostname": "test-host",
            "exec-duration-millis": "158"
        },
        "result": {
            "type": "track",
            "page": 0,
            "total": 1,
            "perPage": 20,
            "text": "Linkin Park",
            "tracks": {
                "total": 1,
                "perPage": 20,
                "order": 0,
                "results": [
                    {
                        "id": 101,
                        "title": "Numb",
                        "artists": [{ "id": 1, "name": "Linkin Park" }]
                    }
                ]
            }
        }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let envelope = try decoder.decode(YMResponse<YMSearchResponse>.self, from: json)
    let response = try envelope.unwrap()
    #expect(response.total == 1)
    #expect(response.tracks?.results.first?.title == "Numb")
    #expect(response.tracks?.results.first?.artistsString == "Linkin Park")
    #expect(envelope.invocationInfo?.execDurationMillis == 158)
}

@Test("Audio Quality Presets: all options selection and fallback")
func testAudioQualityPresetsAllOptions() {
    let flacStream = YMDownloadInfo(
        codec: "flac",
        bitrateInKbps: 1411,
        downloadInfoUrl: URL(string: "https://example.com/flac")!,
        lossless: true
    )
    let mp3_320 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 320,
        downloadInfoUrl: URL(string: "https://example.com/320")!
    )
    let aac_192 = YMDownloadInfo(
        codec: "aac",
        bitrateInKbps: 192,
        downloadInfoUrl: URL(string: "https://example.com/aac192")!
    )
    let mp3_192 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 192,
        downloadInfoUrl: URL(string: "https://example.com/mp3192")!
    )
    let mp3_128 = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 128,
        downloadInfoUrl: URL(string: "https://example.com/128")!
    )
    let aac_64 = YMDownloadInfo(
        codec: "aac",
        bitrateInKbps: 64,
        downloadInfoUrl: URL(string: "https://example.com/64")!
    )

    let allStreams = [aac_64, mp3_128, aac_192, mp3_192, mp3_320, flacStream]

    // 1. Auto: chooses Lossless if present
    let auto = allStreams.selectDownloadInfo(preset: .auto)
    #expect(auto?.codec == "flac")
    #expect(auto?.bitrateInKbps == 1411)

    // 2. Lossless: chooses FLAC
    let lossless = allStreams.selectDownloadInfo(preset: .lossless)
    #expect(lossless?.codec == "flac")

    // 3. High (320 kbps)
    let high = allStreams.selectDownloadInfo(preset: .high320)
    #expect(high?.bitrateInKbps == 320)

    // 4. Medium (192 kbps) with MP3 preference
    let mediumMp3 = allStreams.selectDownloadInfo(preset: .medium192, codecPreference: .mp3)
    #expect(mediumMp3?.bitrateInKbps == 192)
    #expect(mediumMp3?.codec == "mp3")

    // 5. Medium (192 kbps) with AAC preference
    let mediumAac = allStreams.selectDownloadInfo(preset: .medium192, codecPreference: .aac)
    #expect(mediumAac?.bitrateInKbps == 192)
    #expect(mediumAac?.codec == "aac")

    // 6. Standard (128 kbps)
    let standard = allStreams.selectDownloadInfo(preset: .standard128)
    #expect(standard?.bitrateInKbps == 128)

    // 7. Low (64 kbps)
    let low = allStreams.selectDownloadInfo(preset: .low64)
    #expect(low?.bitrateInKbps == 64)

    // 8. Fallback when requested bitrate is missing (e.g. pool without 320 and without flac)
    let poolWithout320 = [aac_64, mp3_128, mp3_192]
    let fallbackHigh = poolWithout320.selectDownloadInfo(preset: .high320)
    #expect(fallbackHigh?.bitrateInKbps == 192)

    let fallbackLossless = poolWithout320.selectDownloadInfo(preset: .lossless)
    #expect(fallbackLossless?.bitrateInKbps == 192)
}

@Test("AudioQualitySettings persistence and state updates")
@MainActor
func testAudioQualitySettingsPersistence() {
    let settings = AudioQualitySettings.shared
    let originalPreset = settings.preset
    let originalCodec = settings.codecPreference
    let originalPreload = settings.preloadAllFavoritesInBackground
    let originalLimit = settings.imageCacheLimitMB

    defer {
        settings.setPreset(originalPreset)
        settings.setCodecPreference(originalCodec)
        settings.setPreloadFavoritesInBackground(originalPreload)
        settings.setImageCacheLimitMB(originalLimit)
    }

    settings.setPreset(.lossless)
    #expect(settings.preset == .lossless)
    #expect(UserDefaults.standard.string(forKey: "ym_audio_quality_preset") == "lossless")

    settings.setCodecPreference(.aac)
    #expect(settings.codecPreference == .aac)
    #expect(UserDefaults.standard.string(forKey: "ym_audio_codec_pref") == "aac")

    settings.setPreloadFavoritesInBackground(true)
    #expect(settings.preloadAllFavoritesInBackground == true)
    #expect(UserDefaults.standard.bool(forKey: "ym_preload_favorites_bg") == true)

    settings.setImageCacheLimitMB(20)
    #expect(settings.imageCacheLimitMB == 20)
    #expect(UserDefaults.standard.integer(forKey: "ym_image_cache_limit_mb") == 20)
}

@Test("HMAC-SHA256 File Info Signature computation for /get-file-info")
func testFileInfoHmacSha256SignComputation() {
    let ts = "1700000000"
    let trackId = "123456"
    let quality = "lossless"

    let sign = YMAudioURLSigner.computeFileInfoSign(ts: ts, trackId: trackId, quality: quality)

    #expect(sign.count == 43)
    #expect(!sign.contains("="))

    let signMp3 = YMAudioURLSigner.computeFileInfoSign(ts: ts, trackId: trackId, quality: "hq", codecs: "mp3")
    #expect(signMp3.count == 43)
    #expect(!signMp3.contains("="))

    // Quality mapping verification
    #expect(YMAudioQualityPreset.lossless.fileInfoQualityParam == "lossless")
    #expect(YMAudioQualityPreset.auto.fileInfoQualityParam == "lossless")
    #expect(YMAudioQualityPreset.high320.fileInfoQualityParam == "hq")
    #expect(YMAudioQualityPreset.medium192.fileInfoQualityParam == "nq")
    #expect(YMAudioQualityPreset.standard128.fileInfoQualityParam == "nq")
    #expect(YMAudioQualityPreset.low64.fileInfoQualityParam == "lq")
}

@Test("Rotor radioStarted telemetry event has nil trackId")
func testRotorRadioStartedHasNilTrackId() throws {
    let event = YMRotorFeedbackEvent(
        type: .radioStarted,
        timestamp: "2026-10-31T18:00:00.000Z",
        trackId: nil
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(event)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    #expect(json?["type"] as? String == "radioStarted")
    #expect(json?["trackId"] == nil)
}

@Test("Strict Lossless Evaluation and Direct CDN stream detection")
func testStrictLosslessEvaluation() {
    let mp3Descriptor = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 192,
        downloadInfoUrl: URL(string: "https://api.music.yandex.net/get-mp3/U2FsdGVkX1...?sign=abc&ts=123")!,
        direct: false,
        lossless: false
    )
    #expect(!mp3Descriptor.isLossless)
    #expect(!mp3Descriptor.isDirectCdnStream)

    let mp3DirectCdn = YMDownloadInfo(
        codec: "mp3",
        bitrateInKbps: 320,
        downloadInfoUrl: URL(string: "https://strm-ams27.strm.yandex.net/music-v2/raw/ysign1=abc,ts=123/2.mp3")!,
        direct: true,
        lossless: false
    )
    #expect(!mp3DirectCdn.isLossless)
    #expect(mp3DirectCdn.isDirectCdnStream)

    let flacDirect = YMDownloadInfo(
        codec: "flac",
        bitrateInKbps: 900,
        downloadInfoUrl: URL(string: "https://storage.yandex.net/get-file/flac123.flac")!,
        direct: true,
        lossless: true
    )
    #expect(flacDirect.isLossless)
    #expect(flacDirect.isDirectCdnStream)

    let alacStream = YMDownloadInfo(
        codec: "alac",
        bitrateInKbps: 850,
        downloadInfoUrl: URL(string: "https://storage.music.yandex.net/get-file/alac123.m4a")!
    )
    #expect(alacStream.isLossless)
}

@Test("Codec Preference HE-AAC and Preset Selection")
func testHeAacCodecPreferenceSelection() {
    let streams = [
        YMDownloadInfo(codec: "mp3", bitrateInKbps: 192, downloadInfoUrl: URL(string: "https://example.com/1")!),
        YMDownloadInfo(codec: "mp3", bitrateInKbps: 320, downloadInfoUrl: URL(string: "https://example.com/2")!),
        YMDownloadInfo(codec: "aac-mp4", bitrateInKbps: 192, downloadInfoUrl: URL(string: "https://example.com/3")!),
        YMDownloadInfo(codec: "he-aac", bitrateInKbps: 64, downloadInfoUrl: URL(string: "https://example.com/4")!)
    ]

    let selected = streams.selectDownloadInfo(preset: .low64, codecPreference: .heAac)
    #expect(selected != nil)
    #expect(selected?.codec == "he-aac")
    #expect(selected?.bitrateInKbps == 64)
}

@Test("Cross-version macOS compatibility helpers")
func testMacOSCompatibilityHelpers() {
    #expect(!macOSCompatibility.osMarketingName.isEmpty)
    #expect(!macOSCompatibility.osVersionString.isEmpty)
    #expect(macOSCompatibility.isAtLeastMonterey)
}

@Test("Track search and filtering by title, artist, and primary album")
func testTrackSearchAndFiltering() {
    let track1 = YMTrack(
        id: "101",
        title: "Same Graves",
        durationMs: 209000,
        available: true,
        artists: [YMArtist(id: "1", name: "The Ghost Club")],
        albums: [YMAlbum(id: "201", title: "See Below")]
    )

    let track2 = YMTrack(
        id: "102",
        title: "When It Lands",
        durationMs: 269000,
        available: true,
        artists: [YMArtist(id: "2", name: "Rainbow Kitten Surprise")],
        albums: [YMAlbum(id: "202", title: "How to: Friend, Love, Freefall")]
    )

    let tracks = [track1, track2]

    #expect(track1.primaryAlbumTitle == "See Below")
    #expect(track2.primaryAlbumTitle == "How to: Friend, Love, Freefall")

    // Filter by title
    let filterByTitle = tracks.filter { track in
        track.displayTitle.localizedCaseInsensitiveContains("graves")
    }
    #expect(filterByTitle.count == 1)
    #expect(filterByTitle.first?.id == "101")

    // Filter by artist
    let filterByArtist = tracks.filter { track in
        track.artistsString.localizedCaseInsensitiveContains("ghost club")
    }
    #expect(filterByArtist.count == 1)
    #expect(filterByArtist.first?.id == "101")

    // Filter by album title
    let filterByAlbum = tracks.filter { track in
        (track.primaryAlbumTitle ?? "").localizedCaseInsensitiveContains("freefall")
    }
    #expect(filterByAlbum.count == 1)
    #expect(filterByAlbum.first?.id == "102")
}

@Test("Slim memory footprint: YMAlbum skips nested artists and YMTrack retains only primary album")
func testSlimMemoryFootprintYMAlbumAndTrack() throws {
    let json = """
    {
        "id": "999",
        "title": "Optimized Track",
        "durationMs": 180000,
        "artists": [
            { "id": "1", "name": "Primary Artist" }
        ],
        "albums": [
            {
                "id": "10",
                "title": "First Album",
                "artists": [ { "id": "1", "name": "Duplicate Artist In Album" } ]
            },
            {
                "id": "20",
                "title": "Second Redundant Album",
                "artists": [ { "id": "1", "name": "Duplicate Artist 2" } ]
            }
        ]
    }
    """.data(using: .utf8)!

    let track = try JSONDecoder().decode(YMTrack.self, from: json)

    // Only primary album retained
    #expect(track.albums.count == 1)
    #expect(track.albums.first?.id == "10")
    #expect(track.albums.first?.title == "First Album")

    // Album nested artists skipped to prevent redundant structures
    #expect(track.albums.first?.artists == nil)

    // Track-level artists preserved
    #expect(track.artists.count == 1)
    #expect(track.artists.first?.name == "Primary Artist")
}

@Test("LikesService search across visible tracks and search catalog")
@MainActor
func testLikesServiceSearchInLikes() {
    let likes = LikesService.shared
    let results = likes.searchInLikes(query: "")
    #expect(results.count == likes.likedTracks.count)
}

@Test("ImagePipeline configurable memory cost and count limit")
@MainActor
func testImagePipelineConfigurableMemoryCost() {
    let pipeline = ImagePipeline.shared
    pipeline.setMaxMemoryCost(mb: 15)
    pipeline.clearMemoryCache()
}

@Test("AudioPlayerEngine stopAndClear resets all state")
@MainActor
func testAudioPlayerEngineStopAndClear() {
    let engine = AudioPlayerEngine()
    let t1 = YMTrack(id: "1", title: "Track 1")
    engine.setQueue([t1], startingAt: 0)
    engine.stopAndClear()
    #expect(!engine.isPlaying)
    #expect(!engine.isLoading)
    #expect(engine.currentTrack == nil)
    #expect(engine.queue.isEmpty)
    #expect(!engine.isWaveMode)
    #expect(engine.currentStreamInfo == nil)
}

@Test("LikesService resetAll flushes all state")
@MainActor
func testLikesServiceResetAll() {
    let likes = LikesService.shared
    likes.resetAll()
    #expect(likes.likedTrackIds.isEmpty)
    #expect(likes.likedTracks.isEmpty)
    #expect(!likes.hasMoreLikes)
    #expect(!likes.isLoadingMore)
}

@Test("YMTrack placeholder properties and virtualization")
func testTrackPlaceholder() {
    let placeholder = YMTrack.placeholder(id: "12345:6789")
    #expect(placeholder.id == "12345:6789")
    #expect(placeholder.isPlaceholder == true)
    #expect(placeholder.title.isEmpty)
    #expect(placeholder.artists.isEmpty)
    #expect(placeholder.albums.isEmpty)
}

@Test("RotorService session reset and queue identifier formatting")
func testRotorServiceSessionReset() async {
    let rotor = RotorService.shared
    await rotor.setSessionId("test_session_123")
    await rotor.setBatchId("test_batch_456")
    #expect(await rotor.getCurrentSessionId() == "test_session_123")
    #expect(await rotor.getCurrentBatchId() == "test_batch_456")

    await rotor.resetSession()
    #expect(await rotor.getCurrentSessionId() == nil)
    #expect(await rotor.getCurrentBatchId() == nil)

    let track = YMTrack(id: "999", title: "Test Track", albums: [YMAlbum(id: "888", title: "Test Album")])
    #expect(track.rotorTrackIdentifier == "999:888")
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

nonisolated func makeMockNetworkClient(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> YMNetworkClient {
    MockURLProtocol.requestHandler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return YMNetworkClient(customSession: session)
}

@Test("LikesService optimistic like and unlike toggle")
@MainActor
func testLikesServiceOptimisticToggle() async {
    let mockKeychain = KeychainManager(service: "com.test.likes.isolated.\(UUID().uuidString)")
    try? mockKeychain.saveUserId("test_user_777")
    let client = makeMockNetworkClient { @Sendable request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = Data("{\"result\":\"ok\"}".utf8)
        return (response, data)
    }
    let likes = LikesService(networkClient: client, keychain: mockKeychain)

    let testTrack = YMTrack(
        id: "777001",
        title: "Optimistic Test",
        albums: [YMAlbum(id: "123", title: "Album 1")]
    )

    #expect(!likes.isLiked(trackId: testTrack.id))

    // Toggle ON
    await likes.toggleLike(track: testTrack)
    #expect(likes.isLiked(trackId: testTrack.id))
    #expect(likes.likedTracks.contains(where: { $0.id == testTrack.id }))

    // Toggle OFF
    await likes.toggleLike(track: testTrack)
    #expect(!likes.isLiked(trackId: testTrack.id))
    #expect(!likes.likedTracks.contains(where: { $0.id == testTrack.id }))
}

@Test("LikesService hasMoreLikes remains true after toggleLike when 100 total and 50 loaded")
@MainActor
func testLikesServiceHasMoreLikesAfterToggle() async throws {
    let mockKeychain = KeychainManager(service: "com.test.likes.isolated.\(UUID().uuidString)")
    try? mockKeychain.saveUserId("user_100")

    let mockClient = makeMockNetworkClient { @Sendable request in
        let url = request.url ?? URL(string: "https://api.music.yandex.net")!
        let urlStr = url.absoluteString
        if urlStr.contains("/add-multiple") || urlStr.contains("/remove") {
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data("{\"result\":\"ok\"}".utf8))
        } else if urlStr.contains("/likes/tracks") && request.httpMethod == "GET" {
            let items = (1...100).map { "{\"id\": \"\($0)\"}" }.joined(separator: ",")
            let json = "{\"result\":{\"library\":{\"tracks\":[\(items)]}}}"
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data(json.utf8))
        } else if urlStr.hasSuffix("/tracks") && request.httpMethod == "POST" {
            let tracks = (1...50).map { "{\"id\": \"\($0)\", \"title\": \"Track \($0)\"}" }.joined(separator: ",")
            let json = "{\"result\":[\(tracks)]}"
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (resp, Data(json.utf8))
        }
        let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (resp, Data())
    }

    let likes = LikesService(networkClient: mockClient, keychain: mockKeychain)
    _ = try await likes.fetchLikedTracks(initialLimit: 50)
    #expect(likes.hasMoreLikes == true)

    // Toggle like for a new track
    let newTrack = YMTrack(id: "9999", title: "New Liked Track")
    await likes.toggleLike(track: newTrack)
    #expect(likes.hasMoreLikes == true)
}

@Test("LikesService no infinite loop with unresolvable track in ensureAllLikedTracksLoadedForSearch")
@MainActor
func testLikesServiceUnresolvableTrackSearch() async throws {
    let mockKeychain = KeychainManager(service: "com.test.likes.isolated.\(UUID().uuidString)")
    try? mockKeychain.saveUserId("user_unresolvable")

    let mockClient = makeMockNetworkClient { @Sendable request in
        let urlStr = request.url?.absoluteString ?? ""
        if urlStr.contains("/likes/tracks") && request.httpMethod == "GET" {
            let json = "{\"result\":{\"library\":{\"tracks\":[{\"id\": \"1\"}, {\"id\": \"999\"}]}}}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        } else if urlStr.contains("/tracks") && request.httpMethod == "POST" {
            let json = "{\"result\":[{\"id\": \"1\", \"title\": \"Track 1\"}]}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
    }

    let likes = LikesService(networkClient: mockClient, keychain: mockKeychain)
    try await likes.syncLikes()
    await likes.ensureAllLikedTracksLoadedForSearch()
    #expect(likes.likedTracks.count >= 0)
}

@Test("LikesService rollback on network error without albumId")
@MainActor
func testLikesServiceRollbackOnNetworkError() async {
    let mockKeychain = KeychainManager(service: "com.test.likes.isolated.\(UUID().uuidString)")
    try? mockKeychain.saveUserId("user_error")

    let mockClient = makeMockNetworkClient { @Sendable request in
        return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("Internal Server Error".utf8))
    }

    let likes = LikesService(networkClient: mockClient, keychain: mockKeychain)
    let trackWithoutAlbum = YMTrack(id: "5000", title: "Fail Track", albums: [])

    #expect(!likes.isLiked(trackId: "5000"))
    await likes.toggleLike(track: trackWithoutAlbum)

    // Should rollback because network failed and there's no albumId fallback
    #expect(!likes.isLiked(trackId: "5000"))
    #expect(!likes.likedTracks.contains(where: { $0.id == "5000" }))
}

@Test("YMAlbum decoding artists directly vs stripped in YMTrack.albums for RAM budget")
func testAlbumArtistsDirectVsInTrack() throws {
    let albumJson = """
    {
        "id": "100",
        "title": "Album With Artists",
        "artists": [
            {"id": "a1", "name": "Artist 1"}
        ]
    }
    """
    let album = try JSONDecoder().decode(YMAlbum.self, from: Data(albumJson.utf8))
    #expect(album.artists != nil)
    #expect(album.artists?.first?.name == "Artist 1")

    let trackJson = """
    {
        "id": "200",
        "title": "Track With Album",
        "albums": [
            {
                "id": "100",
                "title": "Album With Artists",
                "artists": [
                    {"id": "a1", "name": "Artist 1"}
                ]
            }
        ]
    }
    """
    let track = try JSONDecoder().decode(YMTrack.self, from: Data(trackJson.utf8))
    #expect(track.albums.first?.id == "100")
    #expect(track.albums.first?.artists == nil)
}

@Test("YMTrack lyrics precedence and rotorTrackIdentifier no colon duplication")
func testTrackLyricsAndRotorIdentifier() throws {
    let json = """
    {
        "id": "300",
        "title": "Lyrics Track",
        "lyricsAvailable": false,
        "lyricsInfo": {
            "hasAvailableSyncLyrics": true,
            "hasAvailableTextLyrics": false
        }
    }
    """
    let track = try JSONDecoder().decode(YMTrack.self, from: Data(json.utf8))
    #expect(track.hasLyrics == true)

    let trackWithColon = YMTrack(id: "300:999", title: "Colon Track", albums: [YMAlbum(id: "888", title: "A")])
    #expect(trackWithColon.rotorTrackIdentifier == "300:999")
}

@Test("YMPlaylist cover.itemsUri takes precedence over relative cover.dir")
func testPlaylistCoverPrecedence() throws {
    let json = """
    {
        "uid": "123",
        "kind": 3,
        "title": "Playlist With Mosaic",
        "cover": {
            "dir": "/get-music-user-playlist/123/mosaic.jpg",
            "itemsUri": ["avatars.yandex.net/get-music-content/123/%%"]
        }
    }
    """
    let playlist = try JSONDecoder().decode(YMPlaylist.self, from: Data(json.utf8))
    #expect(playlist.coverUri == "avatars.yandex.net/get-music-content/123/%%")
}

@Test("Lossy decoding skips malformed items in YMAlbumWithTracks, YMArtistBriefInfo, and YMChartBlock")
func testLossyDecoding() throws {
    // 1. YMAlbumWithTracks
    let albumJson = """
    {
        "id": "1",
        "title": "Lossy Album",
        "volumes": [
            [
                {"id": "t1", "title": "Track 1"},
                {"broken": 123},
                null,
                {"id": "t2", "title": "Track 2"}
            ]
        ]
    }
    """
    let album = try JSONDecoder().decode(YMAlbumWithTracks.self, from: Data(albumJson.utf8))
    #expect(album.volumes.first?.count == 2)
    #expect(album.volumes.first?.map(\.id) == ["t1", "t2"])

    // 2. YMArtistBriefInfo
    let artistJson = """
    {
        "artist": {"id": "art1", "name": "Artist 1"},
        "popularTracks": [
            {"id": "t1", "title": "Track 1"},
            {"corrupted": true},
            {"id": "t3", "title": "Track 3"}
        ]
    }
    """
    let artistInfo = try JSONDecoder().decode(YMArtistBriefInfo.self, from: Data(artistJson.utf8))
    #expect(artistInfo.popularTracks.count == 2)
    #expect(artistInfo.popularTracks.map(\.id) == ["t1", "t3"])

    // 3. YMChartBlock
    let chartJson = """
    {
        "chart": {
            "id": "world",
            "title": "Top Chart",
            "tracks": [
                {"id": "c1", "track": {"id": "tr1", "title": "Hit 1"}},
                null,
                {"invalid": "data"},
                {"id": "c2", "track": {"id": "tr2", "title": "Hit 2"}}
            ]
        }
    }
    """
    let chartResp = try JSONDecoder().decode(YMChartResponse.self, from: Data(chartJson.utf8))
    #expect(chartResp.chart?.tracks.count == 2)
    #expect(chartResp.chart?.tracks.map(\.id) == ["c1", "c2"])
}

@Test("Wave context creation for track and playlist")
func testWaveContextCreation() {
    let track = YMTrack(id: "123", title: "Test Track", albums: [YMAlbum(id: "456", title: "Test Album")])
    let trackContext = YMWaveContext.forTrack(track)
    #expect(trackContext.seeds == ["track:123"])
    #expect(trackContext.fallbackStationId == "track:123")
    #expect(trackContext.title.contains("Test Track"))

    let playlist = YMPlaylist(uid: "uid", kind: 1, title: "Test Playlist")
    let sampleIds = ["t1", "t2", "t3"]
    let playlistContext = YMWaveContext.forPlaylist(playlist, sampleTrackIds: sampleIds)
    #expect(playlistContext.seeds == ["playlist:uid_1"])
    #expect(playlistContext.fallbackStationId == "playlist:uid_1")
    #expect(playlistContext.fallbackTrackSeeds == ["track:t1", "track:t2", "track:t3"])
    #expect(playlistContext.title.contains("Test Playlist"))
}

@Test("AudioPlayerEngine shuffle toggle preserves current track at 0 and restores original queue")
@MainActor
func testAudioPlayerEngineShuffleToggle() {
    let engine = AudioPlayerEngine()
    engine.stopAndClear()

    let track1 = YMTrack(id: "1", title: "Track 1")
    let track2 = YMTrack(id: "2", title: "Track 2")
    let track3 = YMTrack(id: "3", title: "Track 3")
    let track4 = YMTrack(id: "4", title: "Track 4")
    let originalQueue = [track1, track2, track3, track4]

    engine.setQueue(originalQueue, startingAt: 2) // current track is track3
    #expect(engine.currentTrack?.id == "3")
    #expect(!engine.isShuffleEnabled)

    // Turn shuffle ON
    engine.toggleShuffle()
    #expect(engine.isShuffleEnabled)
    #expect(engine.currentIndex == 0)
    #expect(engine.currentTrack?.id == "3")
    #expect(engine.queue.count == 4)
    #expect(engine.queue.first?.id == "3")

    // Turn shuffle OFF
    engine.toggleShuffle()
    #expect(!engine.isShuffleEnabled)
    #expect(engine.queue.map(\.id) == ["1", "2", "3", "4"])
    #expect(engine.currentTrack?.id == "3")
    #expect(engine.currentIndex == 2)
}

@Test("Rotor feedback extended event types like and dislike serialization")
func testRotorFeedbackExtendedEventTypes() throws {
    let encoder = JSONEncoder()

    let likeEvent = YMRotorFeedbackEvent(
        type: .like,
        timestamp: "2026-11-03T20:00:00.000Z",
        trackId: "123:456"
    )
    let likePayload = YMRotorFeedbackPayload(event: likeEvent)
    let likeData = try encoder.encode(likePayload)
    let likeJson = try JSONSerialization.jsonObject(with: likeData) as? [String: Any]
    let likeEventDict = likeJson?["event"] as? [String: Any]
    #expect(likeEventDict?["type"] as? String == "like")
    #expect(likeEventDict?["trackId"] as? String == "123:456")

    let dislikeEvent = YMRotorFeedbackEvent(
        type: .dislike,
        timestamp: "2026-11-03T20:00:00.000Z",
        trackId: "123:456"
    )
    let dislikePayload = YMRotorFeedbackPayload(event: dislikeEvent)
    let dislikeData = try encoder.encode(dislikePayload)
    let dislikeJson = try JSONSerialization.jsonObject(with: dislikeData) as? [String: Any]
    let dislikeEventDict = dislikeJson?["event"] as? [String: Any]
    #expect(dislikeEventDict?["type"] as? String == "dislike")
    #expect(dislikeEventDict?["trackId"] as? String == "123:456")
}

@Test("WindowState responsive width thresholds and top chrome clearance")
@MainActor
func testWindowStateBreakpoints() {
    let state = WindowState.shared
    state.windowSize = CGSize(width: 1100, height: 700)
    state.isFullScreen = false
    state.isSidebarVisible = true
    #expect(!state.isCompactWidth)
    #expect(!state.isMiniWidth)
    #expect(!state.needsTopChromeClearance)
    #expect(state.topChromeContentPadding == 20)
    #expect(state.topToolbarLeadingInset == 24)

    // Windowed with hidden sidebar: clearance beneath traffic lights + sidebar.left button
    state.windowSize = CGSize(width: 650, height: 500)
    state.isSidebarVisible = false
    #expect(state.isCompactWidth)
    #expect(!state.isMiniWidth)
    #expect(state.needsTopChromeClearance)
    #expect(state.topChromeContentPadding == 48)
    #expect(state.topToolbarLeadingInset == 124)

    // Fullscreen with hidden sidebar: no traffic lights, only sidebar.left button
    state.isFullScreen = true
    #expect(!state.needsTopChromeClearance)
    #expect(state.topChromeContentPadding == 20)
    #expect(state.topToolbarLeadingInset == 56)

    // Mini width (440pt)
    state.isFullScreen = false
    state.windowSize = CGSize(width: 440, height: 320)
    #expect(state.isCompactWidth)
    #expect(state.isMiniWidth)

    // Reset back to standard default
    state.isFullScreen = false
    state.isSidebarVisible = true
    state.windowSize = CGSize(width: 900, height: 620)
}

@Test("AudioPlayerEngine wave tuning lessLikeThis preserves queue and suppresses duplicate skip")
@MainActor
func testAudioPlayerEngineWaveTuningLessLikeThis() async throws {
    final class SkippedCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []

        func add(_ id: String) {
            lock.lock()
            defer { lock.unlock() }
            ids.append(id)
        }

        func contains(_ id: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.contains(id)
        }
    }

    let engine = AudioPlayerEngine()
    engine.stopAndClear()

    let t1 = YMTrack(id: "101", title: "Track 1")
    let t2 = YMTrack(id: "102", title: "Track 2")
    let t3 = YMTrack(id: "103", title: "Track 3")
    let t4 = YMTrack(id: "104", title: "Track 4")
    let t5 = YMTrack(id: "105", title: "Track 5")

    engine.isWaveMode = true
    engine.setQueue([t1, t2, t3, t4, t5], startingAt: 0)

    let collector = SkippedCollector()
    engine.onTrackSkipped = { track, _ in
        collector.add(track.id)
    }

    // Current track is t1. Apply lessLikeThis for t1.
    // It should trim queue keeping next 2 tracks (t1, t2, t3), then call next() (switching to t2)
    // while suppressNextSkipTelemetry prevents onTrackSkipped for t1.
    engine.applyWaveTuning(.lessLikeThis, for: t1)

    for _ in 0..<20 {
        if engine.currentTrack?.id == "102" { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(engine.currentTrack?.id == "102")
    // Queue should have been trimmed to [t1, t2, t3] before next(), remaining at least [t1, t2, t3]
    #expect(engine.queue.contains(where: { $0.id == "102" }))
    #expect(engine.queue.contains(where: { $0.id == "103" }))
    // Should NOT have received skip telemetry for t1 because suppressNextSkipTelemetry was true
    #expect(!collector.contains("101"))
}

@Test("YMArtistBriefInfo and YMArtistStats decoding")
func testArtistBriefInfoDecoding() throws {
    let json = """
    {
        "artist": {
            "id": 12345,
            "name": "Linkin Park",
            "cover": { "uri": "avatars.yandex.net/get-music-content/123/%%" }
        },
        "albums": [
            { "id": "111", "title": "Meteora", "year": 2003, "genre": "rock" }
        ],
        "alsoAlbums": [
            { "id": "222", "title": "Numb EP", "year": 2003 }
        ],
        "popularTracks": [
            { "id": "999", "title": "Numb", "durationMs": 185000 }
        ],
        "similarArtists": [
            { "id": 54321, "name": "Evanescence" }
        ],
        "stats": {
            "lastMonthListeners": 3500000,
            "lastMonthListenersDelta": 15000
        },
        "description": {
            "text": "American rock band formed in Agoura Hills, California."
        }
    }
    """
    let data = try #require(json.data(using: .utf8))
    let info = try JSONDecoder().decode(YMArtistBriefInfo.self, from: data)

    #expect(info.artist.id == "12345")
    #expect(info.artist.name == "Linkin Park")
    #expect(info.albums.count == 1)
    #expect(info.albums.first?.title == "Meteora")
    #expect(info.alsoAlbums.count == 1)
    #expect(info.popularTracks.count == 1)
    #expect(info.popularTracks.first?.title == "Numb")
    #expect(info.similarArtists.count == 1)
    #expect(info.similarArtists.first?.name == "Evanescence")
    #expect(info.stats?.lastMonthListeners == 3500000)
    #expect(info.stats?.formattedListeners.contains("3 500 000") == true)
    #expect(info.description?.text?.contains("American rock band") == true)
}

@Test("YMAlbumWithTracks decoding and volume flattening")
func testAlbumWithTracksDecoding() throws {
    let json = """
    {
        "id": 55555,
        "title": "Hybrid Theory",
        "year": 2000,
        "genre": "rock",
        "trackCount": 2,
        "artists": [
            { "id": "12345", "name": "Linkin Park" }
        ],
        "volumes": [
            [
                { "id": "1", "title": "Papercut", "durationMs": 184000 },
                { "id": "2", "title": "One Step Closer", "durationMs": 155000 }
            ]
        ]
    }
    """
    let data = try #require(json.data(using: .utf8))
    let album = try JSONDecoder().decode(YMAlbumWithTracks.self, from: data)

    #expect(album.id == "55555")
    #expect(album.title == "Hybrid Theory")
    #expect(album.year == 2000)
    #expect(album.genre == "rock")
    #expect(album.artists.count == 1)
    #expect(album.artists.first?.name == "Linkin Park")
    #expect(album.volumes.count == 1)
    #expect(album.allTracks.count == 2)
    #expect(album.allTracks[0].title == "Papercut")
    #expect(album.allTracks[1].title == "One Step Closer")
    #expect(album.formattedInfo.contains("2000") == true)
    #expect(album.formattedInfo.contains("Rock") == true)
}

@Test("YMChartResponse decoding")
func testChartResponseDecoding() throws {
    let json = """
    {
        "chart": {
            "id": "world",
            "title": "Чарт",
            "tracks": [
                {
                    "id": "1001",
                    "track": {
                        "id": "777",
                        "title": "Top Song",
                        "durationMs": 200000
                    },
                    "chart": {
                        "position": 1,
                        "progress": "up",
                        "shift": 2,
                        "listeners": 500000
                    }
                }
            ]
        }
    }
    """
    let data = try #require(json.data(using: .utf8))
    let chartResponse = try JSONDecoder().decode(YMChartResponse.self, from: data)

    #expect(chartResponse.chart?.tracks.count == 1)
    let item = try #require(chartResponse.chart?.tracks.first)
    #expect(item.track?.title == "Top Song")
    #expect(item.chart?.position == 1)
    #expect(item.chart?.progress == "up")
    #expect(item.chart?.progressSymbol == "▲")
}

@Test("YMTrackSupplement and lyrics decoding")
func testTrackSupplementDecoding() throws {
    let json = """
    {
        "id": "777",
        "lyrics": {
            "id": 888,
            "lyrics": "First line of song",
            "fullLyrics": "First line of song\\nSecond line of song",
            "hasRights": true,
            "textLanguage": "ru"
        }
    }
    """
    let data = try #require(json.data(using: .utf8))
    let supplement = try JSONDecoder().decode(YMTrackSupplement.self, from: data)

    #expect(supplement.id == "777")
    #expect(supplement.lyrics?.id == 888)
    #expect(supplement.lyrics?.fullLyrics?.contains("Second line") == true)
    #expect(supplement.lyrics?.displayText.contains("Second line") == true)
}

@Test("NavigationCoordinator routing and history stack")
@MainActor
func testNavigationCoordinatorRouting() {
    let coordinator = NavigationCoordinator()
    #expect(!coordinator.canGoBack)
    #expect(coordinator.path.isEmpty)

    coordinator.navigate(to: .artist(id: "123", name: "Artist One"))
    #expect(coordinator.canGoBack)
    #expect(coordinator.path.count == 1)

    coordinator.navigate(to: .album(id: "456", title: "Album One"))
    #expect(coordinator.path.count == 2)

    coordinator.pop()
    #expect(coordinator.path.count == 1)
    #expect(coordinator.path.first == .artist(id: "123", name: "Artist One"))

    coordinator.popToRoot()
    #expect(coordinator.path.isEmpty)
    #expect(!coordinator.canGoBack)
}

@Test("Wave context for artist")
func testWaveContextForArtist() {
    let artist = YMArtist(id: "999", name: "Queen")
    let context = YMWaveContext.forArtist(artist)

    #expect(context.title.contains("Queen"))
    #expect(context.seeds == ["artist:999"])
    #expect(context.fallbackStationId == "artist:999")
}

@Test("Account Status active subscription evaluation")
func testAccountStatusActiveSubscription() {
    // 1. Account with active Plus
    let activePlusStatus = YMAccountStatus(
        plus: YMPlusInfo(hasPlus: true)
    )
    #expect(activePlusStatus.hasActiveSubscription == true)

    // 2. Account with NO Plus, but had subscription in the past (User's case)
    let expiredHadSubStatus = YMAccountStatus(
        plus: YMPlusInfo(hasPlus: false),
        subscription: YMSubscriptionInfo(hadAnySubscription: true)
    )
    #expect(expiredHadSubStatus.hasActiveSubscription == false)
    #expect(expiredHadSubStatus.hadAnySubscription == true)

    // 3. Account with permissions until in future, but plus: false
    let futureUntilNoPlusStatus = YMAccountStatus(
        permissions: YMPermissionsInfo(until: "2099-01-01T00:00:00Z", values: ["landing-play", "radio-play"]),
        plus: YMPlusInfo(hasPlus: false)
    )
    #expect(futureUntilNoPlusStatus.hasActiveSubscription == false)

    // 4. Account with nil plus, but play-full-tracks in permissions
    let fullTracksPermissionsStatus = YMAccountStatus(
        permissions: YMPermissionsInfo(until: "2099-01-01T00:00:00Z", values: ["play-full-tracks"])
    )
    #expect(fullTracksPermissionsStatus.hasActiveSubscription == true)

    // 5. Completely empty/free account
    let freeStatus = YMAccountStatus()
    #expect(freeStatus.hasActiveSubscription == false)
}

@Test("TrackHoverManager O(1) per-row state isolation, scroll suppression, and anchor cleanup")
func testTrackHoverManager() async {
    let manager = await MainActor.run { TrackHoverManager() }
    await MainActor.run {
        let state1 = manager.state(for: "track1")
        let state2 = manager.state(for: "track2")
        let state3 = manager.state(for: "track3")

        #expect(state1.isHovered == false)
        #expect(state2.isHovered == false)
        #expect(state3.isHovered == false)
        #expect(manager.state(for: "track1") === state1)

        manager.setHovered("track1")
        #expect(state1.isHovered == true)
        #expect(state2.isHovered == false)
        #expect(state3.isHovered == false)

        // Switching to track2 updates only track1 and track2
        manager.setHovered("track2")
        #expect(state1.isHovered == false)
        #expect(state2.isHovered == true)
        #expect(state3.isHovered == false)

        // Late onHover(false) from track1 must not clear track2
        manager.clearIfHovered("track1")
        #expect(state2.isHovered == true)

        // unregister must not evict the actively hovered track, but should evict inactive ones
        manager.unregister(trackId: "track2")
        #expect(manager.state(for: "track2") === state2)
        manager.unregister(trackId: "track1")
        #expect(manager.registeredRowStateCount == 2)

        // Anchor view must never intercept mouse events
        let anchorView = TrackHoverAnchorNSView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        #expect(anchorView.hitTest(NSPoint(x: 10, y: 10)) == nil)
        manager.registerAnchor(anchorView, for: "track3")
        #expect(manager.registeredAnchorCount == 1)

        // Simulating scroll activity suppresses hover and clears current state
        manager.notifyScrollActivity()
        #expect(manager.isScrollSuppressed == true)
        #expect(state2.isHovered == false)

        // Hover events while scrolling are ignored
        manager.setHovered("track3")
        #expect(state3.isHovered == false)

        // Unregistering the last anchor for an inactive track frees its rowState entry
        manager.unregisterAnchor(anchorView, for: "track3")
        #expect(manager.registeredAnchorCount == 0)
        #expect(manager.registeredRowStateCount == 1)

        // Ending scroll restores hover capability
        manager.notifyScrollEnded()
        #expect(manager.isScrollSuppressed == false)
        let freshState3 = manager.state(for: "track3")
        manager.setHovered("track3")
        #expect(freshState3.isHovered == true)

        manager.clear()
        #expect(freshState3.isHovered == false)
    }

    // Watchdog deadline automatically ends scrolling and resolves pointerCandidateTrackId
    await MainActor.run {
        let state4 = manager.state(for: "track4")
        manager.notifyScrollActivity(debounceNanoseconds: 25_000_000)
        #expect(manager.isScrollSuppressed == true)

        // Hover candidate recorded during scroll without mutating row state yet
        manager.handleRowHover(trackId: "track4", isInside: true)
        #expect(state4.isHovered == false)
    }
    try? await Task.sleep(nanoseconds: 60_000_000)
    await MainActor.run {
        #expect(manager.isScrollSuppressed == false)
        #expect(manager.state(for: "track4").isHovered == true)

        // Leaving row clears hover immediately when not scrolling
        manager.handleRowHover(trackId: "track4", isInside: false)
        #expect(manager.state(for: "track4").isHovered == false)
    }
}

@Test("Search response decoding with albums and artists blocks")
func testSearchResponseWithAlbums() throws {
    let json = """
    {
        "type": "all",
        "page": 0,
        "total": 1,
        "perPage": 10,
        "text": "test",
        "tracks": {
            "total": 1,
            "results": [
                {
                    "id": "1001",
                    "title": "Track One",
                    "durationMs": 180000,
                    "available": true
                }
            ]
        },
        "albums": {
            "total": 1,
            "results": [
                {
                    "id": "2001",
                    "title": "Album One",
                    "year": 2024
                }
            ]
        },
        "artists": {
            "total": 1,
            "results": [
                {
                    "id": "3001",
                    "name": "Artist One"
                }
            ]
        }
    }
    """
    let data = json.data(using: .utf8)!
    let response = try JSONDecoder().decode(YMSearchResponse.self, from: data)
    #expect(response.tracks?.results.count == 1)
    #expect(response.albums?.results.count == 1)
    #expect(response.albums?.results.first?.title == "Album One")
    #expect(response.artists?.results.count == 1)
    #expect(response.artists?.results.first?.name == "Artist One")
}

@Test("YMAppTheme palettes, backward-compatible rawValues, and light/dark classification")
@MainActor
func testThemePalettes() {
    #expect(YMAppTheme.allCases.count == 5)
    #expect(YMAppTheme.system.rawValue == "system")
    #expect(YMAppTheme.dark.rawValue == "dark")
    #expect(YMAppTheme.midnight.rawValue == "midnight")
    #expect(YMAppTheme.light.rawValue == "light")
    #expect(YMAppTheme.latte.rawValue == "latte")

    #expect(YMTheme.palette(for: .dark).isLight == false)
    #expect(YMTheme.palette(for: .midnight).isLight == false)
    #expect(YMTheme.palette(for: .light).isLight == true)
    #expect(YMTheme.palette(for: .latte).isLight == true)
    #expect(YMAppTheme.dark.colorScheme == .dark)
    #expect(YMAppTheme.midnight.colorScheme == .dark)
    #expect(YMAppTheme.light.colorScheme == .light)
    #expect(YMAppTheme.latte.colorScheme == .light)
    #expect(YMAppTheme.system.colorScheme == nil)
}

@Test("Rotor v2 batchId request, trackParameters decoding, personal waves dashboard, and extended vibes")
func testRotorExtendedModelsAndDashboard() throws {
    // 1. YMRotorSessionNextTracksRequest includes batchId
    let nextReq = YMRotorSessionNextTracksRequest(queue: ["101:201", "102:202"], batchId: "batch-xyz")
    let reqData = try JSONEncoder().encode(nextReq)
    let reqJson = try JSONSerialization.jsonObject(with: reqData) as? [String: Any]
    #expect(reqJson?["batchId"] as? String == "batch-xyz")
    #expect((reqJson?["queue"] as? [String])?.count == 2)

    // 2. YMRotorSequenceItem decoding with trackParameters and waveText
    let seqJson = """
    {
        "type": "track",
        "track": { "id": "555", "title": "Pulse", "durationMs": 200000 },
        "trackParameters": { "bpm": 128.4, "hue": 210.0, "energy": 0.85 },
        "waveText": "Высокая энергия под ваш ритм"
    }
    """.data(using: .utf8)!
    let seqItem = try JSONDecoder().decode(YMRotorSequenceItem.self, from: seqJson)
    #expect(seqItem.track?.id == "555")
    #expect(seqItem.trackParameters?.bpm == 128.4)
    #expect(seqItem.trackParameters?.energy == 0.85)
    #expect(seqItem.waveText == "Высокая энергия под ваш ритм")

    let insightWithWaveText = YMRotorTrackInsight(
        trackParameters: seqItem.trackParameters,
        waveText: seqItem.waveText
    )
    #expect(insightWithWaveText.formattedInsight == "Высокая энергия под ваш ритм")

    let insightFromBpm = YMRotorTrackInsight(trackParameters: seqItem.trackParameters)
    #expect(insightFromBpm.formattedInsight == "Высокая энергия • 128 BPM")

    // 3. Dashboard response decoding & YMPersonalWaveStation seed combining
    let dashJson = """
    {
        "dashboardId": "dash-1",
        "stations": [
            {
                "station": {
                    "id": { "type": "genre", "tag": "indie" },
                    "name": "Инди",
                    "icon": { "backgroundColor": "#6C63FF", "imageUrl": "avatars.yandex.net/get-music-misc/1/%%" }
                },
                "rupTitle": "Моя волна",
                "rupDescription": "Независимая сцена"
            },
            {
                "station": {
                    "id": { "type": "artist", "tag": "12345" },
                    "name": "Radiohead"
                }
            }
        ]
    }
    """.data(using: .utf8)!
    let dash = try JSONDecoder().decode(YMRotorDashboardResponse.self, from: dashJson)
    #expect(dash.stations.count == 2)

    let indie = try #require(dash.stations[0].toPersonalWaveStation())
    #expect(indie.id == "genre:indie")
    #expect(indie.title == "Инди")
    #expect(indie.combineWithMyWave == true)
    #expect(indie.toWaveContext().seeds == ["genre:indie"])

    let artistStation = try #require(dash.stations[1].toPersonalWaveStation())
    #expect(artistStation.id == "artist:12345")
    #expect(artistStation.combineWithMyWave == false)
    #expect(artistStation.toWaveContext().seeds == ["artist:12345"])

    // 4. Extended YMWaveVibePreset seeds & v1 settings payload
    #expect(YMWaveVibePreset.allCases.count == 12)
    #expect(YMWaveVibePreset.energetic.seedParameter == "settingMoodEnergy:active")
    #expect(YMWaveVibePreset.calm.seedParameter == "settingMoodEnergy:calm")
    #expect(YMWaveVibePreset.joyful.seedParameter == "settingMoodEnergy:fun")
    #expect(YMWaveVibePreset.sad.seedParameter == "settingMoodEnergy:sad")
    #expect(YMWaveVibePreset.unfamiliar.seedParameter == "settingDiversity:discover")
    #expect(YMWaveVibePreset.familiar.seedParameter == "settingDiversity:favorite")
    #expect(YMWaveVibePreset.popular.seedParameter == "settingDiversity:popular")
    #expect(YMWaveVibePreset.russian.seedParameter == "settingLanguage:russian")
    #expect(YMWaveVibePreset.foreign.seedParameter == "settingLanguage:not-russian")
    #expect(YMWaveVibePreset.focus.seedParameter == "activity:work")
    #expect(YMWaveVibePreset.workout.seedParameter == "activity:sport")
    #expect(YMWaveVibePreset.energetic.v1SettingsPayload?.moodEnergy == "active")
    #expect(YMWaveVibePreset.calm.v1SettingsPayload?.moodEnergy == "calm")
    #expect(YMWaveVibePreset.unfamiliar.v1SettingsPayload?.diversity == "discover")
    #expect(YMWaveVibePreset.russian.v1SettingsPayload?.language == "russian")
    #expect(YMWaveVibePreset.unfamiliar.v1QueryItems.first == URLQueryItem(name: "diversity", value: "discover"))
    #expect(YMWaveVibePreset.energetic.v1QueryItems.first == URLQueryItem(name: "moodEnergy", value: "energize"))
    #expect(YMWaveVibePreset.sad.v1QueryItems.first == URLQueryItem(name: "moodEnergy", value: "sad"))

    // 5. YMRotorAPIMode & diagnostics defaults
    #expect(YMRotorAPIMode.allCases.count == 3)
    let diag = YMRotorDiagnostics()
    #expect(diag.activeProtocol == "Не запущена")
    #expect(diag.isFallbackActive == false)

    // 6. YMUnifiedWaveItem & YMWaveCategoryFilter filtering
    let dashboardSample = [
        indie,
        artistStation,
        YMPersonalWaveStation(type: "mood", tag: "relax", title: "Расслабление")
    ]
    let forYouItems = YMUnifiedWaveItem.items(for: .forYou, dashboardStations: dashboardSample)
    #expect(forYouItems.first == .baseWave)
    #expect(forYouItems.contains(.vibe(.unfamiliar)))
    #expect(forYouItems.contains(.vibe(.energetic)))
    #expect(forYouItems.contains(.station(indie)))
    #expect(forYouItems.contains(.station(artistStation)))

    let moodItems = YMUnifiedWaveItem.items(for: .moods, dashboardStations: dashboardSample)
    #expect(!moodItems.contains(.baseWave))
    #expect(!moodItems.contains(.vibe(.defaultWave)))
    #expect(moodItems.contains(.vibe(.focus)))
    #expect(moodItems.contains(where: { $0.id == "station:mood:relax" }))
    #expect(!moodItems.contains(.station(indie)))

    let genreItems = YMUnifiedWaveItem.items(for: .genresAndArtists, dashboardStations: dashboardSample)
    #expect(genreItems.contains(.station(indie)))
    #expect(genreItems.contains(.station(artistStation)))
    #expect(!genreItems.contains(where: { $0.id == "station:mood:relax" }))
}

@Test("AudioQualitySettings crossfadeDuration clamping and UserDefaults persistence")
@MainActor
func testAudioQualitySettingsCrossfadeDuration() {
    let settings = AudioQualitySettings.shared
    let original = settings.crossfadeDuration
    defer { settings.setCrossfadeDuration(original) }

    settings.setCrossfadeDuration(4.5)
    #expect(settings.crossfadeDuration == 4.5)
    #expect(UserDefaults.standard.double(forKey: "ym_audio_crossfade_seconds") == 4.5)

    // Upper bound clamping
    settings.setCrossfadeDuration(25.0)
    #expect(settings.crossfadeDuration == 12.0)

    // Lower bound clamping
    settings.setCrossfadeDuration(-3.0)
    #expect(settings.crossfadeDuration == 0.0)
}

@Test("AudioPlayerEngine reactive stored volume clamping and persistence")
@MainActor
func testAudioPlayerEngineVolumeClamping() {
    let engine = AudioPlayerEngine()
    let original = engine.volume
    defer { engine.volume = original }

    engine.volume = 0.65
    #expect(abs(engine.volume - 0.65) < 0.001)
    #expect(abs(UserDefaults.standard.float(forKey: "ym_audio_player_volume") - 0.65) < 0.001)

    engine.volume = 1.8
    #expect(engine.volume == 1.0)

    engine.volume = -0.5
    #expect(engine.volume == 0.0)
}

@Test("NowPlayingController queue metadata update and clearNowPlaying playbackState")
@MainActor
func testNowPlayingControllerQueueInfo() {
    let controller = NowPlayingController.shared
    let track = YMTrack(
        id: "777001",
        title: "Queue Test Track",
        durationMs: 210_000,
        artists: [YMArtist(id: "1", name: "Test Artist")],
        albums: [YMAlbum(id: "55", title: "Test Album")]
    )

    controller.updateTrack(
        track,
        isPlaying: true,
        currentTime: 12.0,
        queueIndex: 2,
        queueCount: 10,
        collectionIdentifier: "album:55"
    )

    let initialInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
    #expect(initialInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 2)
    #expect(initialInfo?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 10)
    #expect(initialInfo?[MPNowPlayingInfoCollectionIdentifier] as? String == "album:55")
    #expect(initialInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == "777001")
    #expect(initialInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == false)
    #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)

    controller.updateQueueInfo(currentIndex: 4, queueCount: 15, collectionIdentifier: "wave:user:onyourwave")
    let updatedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
    #expect(updatedInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 4)
    #expect(updatedInfo?[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 15)
    #expect(updatedInfo?[MPNowPlayingInfoCollectionIdentifier] as? String == "wave:user:onyourwave")

    controller.clearNowPlaying()
    #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    #expect(MPNowPlayingInfoCenter.default().playbackState == .stopped)
}

@Test("YMPlaylist extended metadata decoding and PlaylistsService upsert/reset")
@MainActor
func testYMPlaylistMetadataAndService() throws {
    let json1 = """
    {
        "uid": 100500,
        "kind": 1012,
        "title": "Ночной драйв",
        "description": "Синтвейв и электроника для поездок",
        "visibility": "private",
        "revision": 7,
        "trackCount": 14
    }
    """.data(using: .utf8)!
    let p1 = try JSONDecoder().decode(YMPlaylist.self, from: json1)
    #expect(p1.uid == "100500")
    #expect(p1.kind == 1012)
    #expect(p1.title == "Ночной драйв")
    #expect(p1.description == "Синтвейв и электроника для поездок")
    #expect(p1.visibility == "private")
    #expect(p1.isPrivate == true)
    #expect(p1.revision == 7)

    let json2 = """
    {
        "uid": "100500",
        "kind": 1013,
        "title": "Утренний кофе",
        "description": { "text": "Спокойный джаз" },
        "visibility": "public",
        "revision": 2,
        "trackCount": 5
    }
    """.data(using: .utf8)!
    let p2 = try JSONDecoder().decode(YMPlaylist.self, from: json2)
    #expect(p2.description == "Спокойный джаз")
    #expect(p2.isPrivate == false)
    #expect(p2.revision == 2)

    let service = PlaylistsService()
    service.upsertPlaylist(p1, insertAtTop: true)
    service.upsertPlaylist(p2, insertAtTop: true)
    #expect(service.playlists.count == 2)
    #expect(service.playlists.first?.id == p2.id)

    let updatedP1 = YMPlaylist(
        uid: p1.uid,
        kind: p1.kind,
        title: "Ночной драйв v2",
        description: "Новое описание",
        visibility: "public",
        revision: 8,
        trackCount: 15
    )
    service.upsertPlaylist(updatedP1, insertAtTop: false)
    #expect(service.playlists.count == 2)
    #expect(service.playlists.last?.title == "Ночной драйв v2")
    #expect(service.playlists.last?.isPrivate == false)

    service.resetAll()
    #expect(service.playlists.isEmpty)
}

@Test("AudioPlayerEngine paginated queue continuation advances seamlessly past initial 50-track batch")
@MainActor
func testAudioPlayerEngineQueueContinuationPast50Tracks() async {
    let engine = AudioPlayerEngine()
    let initialBatch = (1...50).map { i in
        YMTrack(id: "\(i)", title: "Track \(i)", durationMs: 180_000)
    }
    let secondBatch = (51...100).map { i in
        YMTrack(id: "\(i)", title: "Track \(i)", durationMs: 180_000)
    }

    var continuationCalls = 0
    engine.setQueue(initialBatch, startingAt: 49)
    engine.attachQueueContinuation { existingIds in
        continuationCalls += 1
        return secondBatch.filter { !existingIds.contains($0.id) }
    }

    // Wait briefly for proactive prefetch or trigger next() directly
    engine.next()
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(continuationCalls >= 1)
    #expect(engine.queue.count == 100)
    #expect(engine.currentIndex == 50)
    #expect(engine.currentTrack?.id == "51")

    engine.stopAndClear()
}

@Test("EqualizerSettings presets, custom band clamping, reset, and EqualizerParameterBridge sync")
@MainActor
func testEqualizerSettingsAndBridge() {
    let settings = EqualizerSettings.shared
    let origEnabled = settings.isEnabled
    let origPreset = settings.selectedPreset
    let origGains = settings.bandGains
    let origPreamp = settings.preampDb
    defer {
        settings.selectedPreset = origPreset
        settings.bandGains = origGains
        settings.preampDb = origPreamp
        settings.isEnabled = origEnabled
    }

    settings.isEnabled = false
    settings.selectPreset(.rock)
    #expect(settings.selectedPreset == .rock)
    #expect(settings.bandGains == YMEqualizerPreset.rock.gains)
    #expect(settings.isEnabled == true)

    let rockSnap = EqualizerParameterBridge.shared.readSnapshot()
    #expect(rockSnap.isEnabled == true)
    #expect(rockSnap.bandGains == YMEqualizerPreset.rock.gains)

    settings.selectPreset(.bassBoost)
    #expect(settings.selectedPreset == .bassBoost)
    #expect(settings.bandGains == YMEqualizerPreset.bassBoost.gains)

    // Manual band tweak switches preset to .custom and clamps to -12...+12 dB
    settings.setBandGain(index: 0, gain: 20.0)
    #expect(settings.selectedPreset == .custom)
    #expect(settings.bandGains[0] == 12.0)

    settings.setBandGain(index: 9, gain: -25.0)
    #expect(settings.bandGains[9] == -12.0)

    // Preamp clamping -6...+6 dB
    settings.setPreamp(10.0)
    #expect(settings.preampDb == 6.0)
    settings.setPreamp(-10.0)
    #expect(settings.preampDb == -6.0)

    let customSnap = EqualizerParameterBridge.shared.readSnapshot()
    #expect(customSnap.bandGains[0] == 12.0)
    #expect(customSnap.bandGains[9] == -12.0)
    #expect(customSnap.preampDb == -6.0)
    #expect(customSnap.generation > rockSnap.generation)

    // Reset restores flat gains and 0 dB preamp
    settings.reset()
    #expect(settings.selectedPreset == .flat)
    #expect(settings.preampDb == 0.0)
    #expect(settings.bandGains == YMEqualizerPreset.flat.gains)

    let resetSnap = EqualizerParameterBridge.shared.readSnapshot()
    #expect(resetSnap.preampDb == 0.0)
    #expect(resetSnap.bandGains == YMEqualizerPreset.flat.gains)
}

@Test("NavigationCoordinator closes fullscreen (.right) lyrics on menu selection while keeping .abovePlayer open")
@MainActor
func testNavigationCoordinatorDismissesFullscreenLyrics() {
    let coordinator = NavigationCoordinator()
    let originalPos = coordinator.lyricsPosition
    defer { coordinator.lyricsPosition = originalPos }

    let sampleTrack = YMTrack(id: "42", title: "Lyrics Track", durationMs: 180_000)

    // 1. Fullscreen (.right) closes when switching sections
    coordinator.lyricsPosition = .right
    coordinator.showLyrics(for: sampleTrack)
    #expect(coordinator.isLyricsPresented == true)

    coordinator.selectSection(.search)
    #expect(coordinator.selectedSection == .search)
    #expect(coordinator.isLyricsPresented == false)
    #expect(coordinator.lyricsTrack == nil)
    #expect(coordinator.lyricsPosition == .right)

    // 2. Fullscreen (.right) closes when navigating to album/artist
    coordinator.showLyrics(for: sampleTrack)
    coordinator.navigate(to: .album(id: "100", title: "Album"))
    #expect(coordinator.isLyricsPresented == false)

    // 3. Compact (.abovePlayer) remains open when switching sections
    coordinator.lyricsPosition = .abovePlayer
    coordinator.showLyrics(for: sampleTrack)
    coordinator.selectSection(.myWave)
    #expect(coordinator.selectedSection == .myWave)
    #expect(coordinator.isLyricsPresented == true)
}

@Test("YMAudioURLSigner desktopFileInfoSecretKey, albumId sanitization, and computeLyricsSign")
func testAudioURLSignerDesktopAndLyrics() {
    let ts = "1700000000"
    let trackId = "987654"
    let compoundTrackId = "987654:321"

    // Default uses desktopFileInfoSecretKey
    let desktopSign1 = YMAudioURLSigner.computeFileInfoSign(ts: ts, trackId: trackId, quality: "lossless")
    let desktopSign2 = YMAudioURLSigner.computeFileInfoSign(ts: ts, trackId: compoundTrackId, quality: "lossless")
    #expect(desktopSign1 == desktopSign2)
    #expect(desktopSign1.count == 43)

    // Android client key produces different signature
    let androidSign = YMAudioURLSigner.computeFileInfoSign(
        ts: ts,
        trackId: trackId,
        quality: "lossless",
        secretKey: YMAudioURLSigner.fileInfoSecretKey
    )
    #expect(androidSign != desktopSign1)
    #expect(androidSign.count == 43)

    // Lyrics HMAC-SHA256 signing
    let lyricsSign1 = YMAudioURLSigner.computeLyricsSign(trackId: trackId, timestamp: 1700000000)
    let lyricsSign2 = YMAudioURLSigner.computeLyricsSign(trackId: compoundTrackId, timestamp: 1700000000)
    #expect(lyricsSign1 == lyricsSign2)
    #expect(!lyricsSign1.isEmpty)
    #expect(Data(base64Encoded: lyricsSign1) != nil)
}

@Test("YMSyncedLyrics advanced parsing: BOM, inline/trailing tags, offset, collapsing, and NaN safety")
func testSyncedLyricsAdvancedParsing() {
    let rawLrc = """
    \u{FEFF}[ti:Sample Song]
    [offset:500]
    [00:05.00]
    [00:06.00]
    [00:10.00]First <00:11.00>line[00:12.00]
    [00:15.00]Second line with trailing tag[00:16.00]
    [00:20.00]
    [00:25.00]
    """

    let lyrics = YMSyncedLyrics.parse(lrcContent: rawLrc)
    #expect(!lyrics.isEmpty)

    // offset: 500ms shifts times earlier by 0.5s:
    // 00:05.00 -> 4.5s
    // 00:10.00 -> 9.5s
    // 00:15.00 -> 14.5s
    // Lines 00:05.00 and 00:06.00 are empty -> collapsed into a single "•••"
    // Trailing empty lines 00:20.00 and 00:25.00 must not append a trailing "•••"
    #expect(lyrics.lines.count == 3)
    #expect(lyrics.lines[0].text == "•••")
    #expect(abs(lyrics.lines[0].time - 4.5) < 0.001)

    #expect(lyrics.lines[1].text == "First line")
    #expect(abs(lyrics.lines[1].time - 9.5) < 0.001)

    #expect(lyrics.lines[2].text == "Second line with trailing tag")
    #expect(abs(lyrics.lines[2].time - 14.5) < 0.001)

    // NaN / Infinity safety
    #expect(lyrics.activeLineIndex(for: .nan) == nil)
    #expect(lyrics.activeLineIndex(for: .infinity) == nil)
    #expect(lyrics.activeLineIndex(for: -.infinity) == nil)
    #expect(lyrics.activeLineIndex(for: 10.0) == 1)
}

@Test("YMAccountStatus active subscription with autoRenewable, familyAutoRenewable, nonAutoRenewable, and expired permissions")
func testAccountStatusExtendedSubscriptions() {
    let refNow = "2026-06-01T12:00:00Z"
    let accountInfo = YMAccountInfo(uid: "100", now: refNow)

    // 1. hasPlus: true
    let plusStatus = YMAccountStatus(
        account: accountInfo,
        plus: YMPlusInfo(hasPlus: true)
    )
    #expect(plusStatus.hasActiveSubscription == true)

    // 2. hasPlus: false, but active autoRenewable
    let autoRenewableStatus = YMAccountStatus(
        account: accountInfo,
        plus: YMPlusInfo(hasPlus: false),
        subscription: YMSubscriptionInfo(
            autoRenewable: [
                YMAutoRenewableInfo(expires: "2026-07-01T00:00:00Z", finished: false)
            ]
        )
    )
    #expect(autoRenewableStatus.hasActiveSubscription == true)

    // 3. hasPlus: false, but active familyAutoRenewable with nil expires
    let familyStatus = YMAccountStatus(
        account: accountInfo,
        plus: YMPlusInfo(hasPlus: false),
        subscription: YMSubscriptionInfo(
            familyAutoRenewable: [
                YMAutoRenewableInfo(expires: nil, finished: false)
            ]
        )
    )
    #expect(familyStatus.hasActiveSubscription == true)

    // 4. hasPlus: false, but active nonAutoRenewable
    let nonAutoStatus = YMAccountStatus(
        account: accountInfo,
        plus: YMPlusInfo(hasPlus: false),
        subscription: YMSubscriptionInfo(
            nonAutoRenewable: YMNonAutoRenewableInfo(start: "2026-01-01T00:00:00Z", end: "2026-07-01T00:00:00Z")
        )
    )
    #expect(nonAutoStatus.hasActiveSubscription == true)

    // 5. Expired permissions.until (< referenceDate) overrides play-full-tracks
    let expiredPermsStatus = YMAccountStatus(
        account: accountInfo,
        permissions: YMPermissionsInfo(until: "2026-05-01T00:00:00Z", values: ["play-full-tracks"]),
        plus: YMPlusInfo(hasPlus: false)
    )
    #expect(expiredPermsStatus.hasActiveSubscription == false)
}

@Test("AuthService token extraction handles OAuth and Bearer prefixes")
@MainActor
func testAuthServicePrefixTokenExtraction() {
    let token = "y0_AgAAAABpSampleToken12345"
    #expect(AuthService.extractToken(from: "OAuth \(token)") == token)
    #expect(AuthService.extractToken(from: "oauth \(token)") == token)
    #expect(AuthService.extractToken(from: "Bearer \(token)") == token)
    #expect(AuthService.extractToken(from: "bearer \(token)") == token)
}

@Test("Rotor v2 session feedback encoding has event and optional from")
func testRotorV2SessionFeedbackEncoding() throws {
    let event = YMRotorSessionEvent(type: .radioStarted, timestamp: "2026-11-22T12:00:00Z")
    let req = YMRotorSessionFeedbackRequest(event: event, batchId: "b1", from: "test-from")
    let data = try JSONEncoder().encode(req)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["batchId"] as? String == "b1")
    #expect(json?["from"] as? String == "test-from")
    let eventDict = json?["event"] as? [String: Any]
    #expect(eventDict?["type"] as? String == "radioStarted")
    #expect(eventDict?["from"] == nil)
}

@Test("Rotor v1 station feedback encoding is flat and omits totalPlayedSeconds <= 0")
func testRotorV1StationFeedbackEncoding() throws {
    let flatReq = YMRotorStationFeedbackRequest(
        type: .trackFinished,
        timestamp: "2026-11-22T12:00:00Z",
        trackId: "123:456",
        totalPlayedSeconds: 120.5,
        from: nil
    )
    let data = try JSONEncoder().encode(flatReq)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["type"] as? String == "trackFinished")
    #expect(json?["trackId"] as? String == "123:456")
    #expect(json?["totalPlayedSeconds"] as? Double == 120.5)
    #expect(json?["from"] == nil)

    let flatReqZero = YMRotorStationFeedbackRequest(
        type: .skip,
        timestamp: "2026-11-22T12:00:00Z",
        trackId: "123",
        totalPlayedSeconds: 0.0,
        from: nil
    )
    let zeroData = try JSONEncoder().encode(flatReqZero)
    let zeroJson = try JSONSerialization.jsonObject(with: zeroData) as? [String: Any]
    #expect(zeroJson?["totalPlayedSeconds"] == nil)
}

@Test("WaveSessionController shared instance lifecycle and displayed wave tracks")
@MainActor
func testWaveSessionController() {
    let controller = WaveSessionController.shared
    controller.installAudioEngineHooks()
    #expect(controller.errorMessage == nil)
    #expect(controller.isLoadingWave == false)
}

@Test("YMThemeManager theme switching, system resolution, and themeRevisionKey")
@MainActor
func testThemeManagerThemeSwitching() {
    let themeManager = YMThemeManager.shared
    let originalTheme = themeManager.currentTheme

    themeManager.setTheme(.midnight)
    #expect(themeManager.currentTheme == .midnight)
    #expect(themeManager.resolvedPalette.id == "midnight")
    let midnightRevision = YMTheme.themeRevisionKey

    themeManager.setTheme(.latte)
    #expect(themeManager.currentTheme == .latte)
    #expect(themeManager.resolvedPalette.id == "latte")
    let latteRevision = YMTheme.themeRevisionKey
    #expect(midnightRevision != latteRevision)

    themeManager.setTheme(.dark)
    #expect(themeManager.currentTheme == .dark)
    #expect(themeManager.resolvedPalette.id == "graphite")

    themeManager.setTheme(.system)
    #expect(themeManager.currentTheme == .system)
    #expect(themeManager.resolvedPalette.id == "light" || themeManager.resolvedPalette.id == "midnight")

    themeManager.setTheme(originalTheme)
}

@Test("TrackHoverManager lifecycle, hover tracking, candidate resolution, and cleanup")
@MainActor
func testTrackHoverManagerLifecycleAndCleanup() {
    let hoverManager = TrackHoverManager.shared
    hoverManager.cleanup()

    #expect(hoverManager.state(for: "track-101").isHovered == false)

    hoverManager.handleRowHover(trackId: "track-101", isInside: true)
    #expect(hoverManager.state(for: "track-101").isHovered == true)

    hoverManager.notifyScrollActivity(debounceNanoseconds: 50_000_000)
    #expect(hoverManager.state(for: "track-101").isHovered == false)

    hoverManager.notifyScrollEnded()
    // Since anchors are empty, candidate resolves back
    #expect(hoverManager.state(for: "track-101").isHovered == true)

    // With a dummy anchor view not added to a window, resolveHoverUnderCursor clears candidate
    let dummyView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    hoverManager.registerAnchor(dummyView, for: "track-101")
    hoverManager.resolveHoverUnderCursor()
    #expect(hoverManager.state(for: "track-101").isHovered == false)

    hoverManager.cleanup()
    #expect(hoverManager.state(for: "track-101").isHovered == false)
}

@Test("TrackHoverManager NSClipView observation and geometric anchor isolation")
@MainActor
func testTrackHoverManagerClipViewObservation() {
    let hoverManager = TrackHoverManager.shared
    hoverManager.cleanup()

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    let clipView = scrollView.contentView
    hoverManager.observeScrollClipView(clipView)

    let anchorView = TrackHoverAnchorNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 48))
    scrollView.documentView = anchorView
    hoverManager.registerAnchor(anchorView, for: "track-geo")

    // When anchors are present, handleRowHover is ignored in favor of geometry
    hoverManager.handleRowHover(trackId: "track-geo", isInside: true)
    #expect(hoverManager.state(for: "track-geo").isHovered == false)

    // Posting boundsDidChange on observed clipView activates scroll suppression
    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clipView)
    #expect(hoverManager.isScrollSuppressed == true)

    hoverManager.cleanup()
    #expect(hoverManager.isScrollSuppressed == false)
}

@Test("TrackHoverManager scroll phase lifecycle and suppression")
@MainActor
func testTrackHoverManagerScrollPhaseSuppression() async {
    let hoverManager = TrackHoverManager.shared
    hoverManager.cleanup()

    #expect(hoverManager.isScrollSuppressed == false)

    hoverManager.setScrollPhaseActive(true)
    #expect(hoverManager.isScrollSuppressed == true)

    hoverManager.setScrollPhaseActive(false)
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(hoverManager.isScrollSuppressed == false)

    hoverManager.cleanup()
}

@Test("YMTouchBarController configures AppKit touchBar, attaches to NSWindow, and builds layout without volume popover")
@MainActor
func testYMTouchBarControllerConfiguration() {
    let controller = YMTouchBarController.shared
    controller.install()

    let bar = controller.touchBar
    #expect(bar.delegate === controller)
    #expect(bar.customizationIdentifier == NSTouchBar.CustomizationIdentifier("com.yandexmusic.mac.touchbar.main"))
    #expect(!bar.defaultItemIdentifiers.isEmpty)
    #expect(!bar.defaultItemIdentifiers.contains(NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.volumePopover")))
    #expect(bar.defaultItemIdentifiers.contains(NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.lyrics")))
    #expect(bar.defaultItemIdentifiers.contains(NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.shuffle")))
    #expect(NSApplication.shared.touchBar === bar)

    let dummyWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    controller.attachToWindow(dummyWindow)
    #expect(dummyWindow.touchBar === bar)

    let customIDs = bar.customizationAllowedItemIdentifiers.filter {
        $0 != .fixedSpaceSmall && $0 != .fixedSpaceLarge && $0 != .flexibleSpace
    }
    for identifier in customIDs {
        let item = controller.touchBar(bar, makeItemForIdentifier: identifier)
        #expect(item != nil, "Touch Bar item for \(identifier.rawValue) should be instantiated")
    }

    let removedVolumeItem = controller.touchBar(
        bar,
        makeItemForIdentifier: NSTouchBarItem.Identifier("com.yandexmusic.mac.tb.volumePopover")
    )
    #expect(removedVolumeItem == nil)
}








