import Testing
import Foundation
import AppKit
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

@Test("KeychainManager operations")
func testKeychainManager() throws {
    let manager = KeychainManager(service: "com.yandexmusic.mac.tests.\(UUID().uuidString)")
    let token = "test_oauth_token_12345"
    let userId = "998877"

    try manager.saveToken(token)
    try manager.saveUserId(userId)

    #expect(manager.getToken() == token)
    #expect(manager.getUserId() == userId)

    try manager.deleteToken()
    #expect(manager.getToken() == nil)
    #expect(manager.getUserId() == userId)

    try manager.clearAll()
    #expect(manager.getToken() == nil)
    #expect(manager.getUserId() == nil)
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
func testImagePipeline() async {
    let pipeline = ImagePipeline(maxMemoryCost: 10 * 1024 * 1024)
    await pipeline.clearCache()

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
func testImagePipelineConfigurableMemoryCost() async {
    let pipeline = ImagePipeline.shared
    await pipeline.setMaxMemoryCost(mb: 15)
    await pipeline.clearMemoryCache()
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

@Test("LikesService optimistic like and unlike toggle")
@MainActor
func testLikesServiceOptimisticToggle() async {
    let mockKeychain = KeychainManager(service: "com.test.likes.isolated.\(UUID().uuidString)")
    let likes = LikesService(keychain: mockKeychain)

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
    #expect(playlistContext.seeds == ["playlist:uid_1", "track:t1", "track:t2", "track:t3"])
    #expect(playlistContext.fallbackStationId == "user:onyourwave")
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

@Test("WindowState responsive width thresholds")
@MainActor
func testWindowStateBreakpoints() {
    let state = WindowState.shared
    state.windowSize = CGSize(width: 900, height: 620)
    #expect(!state.isCompactWidth)
    #expect(!state.isMiniWidth)

    state.windowSize = CGSize(width: 650, height: 500)
    #expect(state.isCompactWidth)
    #expect(!state.isMiniWidth)

    state.windowSize = CGSize(width: 500, height: 400)
    #expect(state.isCompactWidth)
    #expect(state.isMiniWidth)

    // Reset back to standard default
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

    // 3. Account with future permissions until date
    let futureUntilStatus = YMAccountStatus(
        permissions: YMPermissionsInfo(until: "2099-01-01T00:00:00Z"),
        plus: YMPlusInfo(hasPlus: false)
    )
    #expect(futureUntilStatus.hasActiveSubscription == true)

    // 4. Account with expired permissions until date
    let expiredUntilStatus = YMAccountStatus(
        permissions: YMPermissionsInfo(until: "2020-01-01T00:00:00Z"),
        plus: YMPlusInfo(hasPlus: false)
    )
    #expect(expiredUntilStatus.hasActiveSubscription == false)

    // 5. Completely empty/free account
    let freeStatus = YMAccountStatus()
    #expect(freeStatus.hasActiveSubscription == false)
}



