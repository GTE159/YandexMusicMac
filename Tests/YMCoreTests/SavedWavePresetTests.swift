import Testing
import Foundation
@testable import YMCore

@Suite("Saved Wave Presets, Taste Tracker, Immutability & Rotor Seeds Tests")
struct SavedWavePresetTests {

    private func makeTempStoreURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YMSavedWavesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("saved_waves.json", isDirectory: false)
    }

    private func makeTrack(
        id: String,
        title: String,
        artistId: String,
        artistName: String,
        albumId: String = "al1",
        durationMs: Int = 180_000
    ) -> YMTrack {
        YMTrack(
            id: id,
            title: title,
            durationMs: durationMs,
            artists: [YMArtist(id: artistId, name: artistName)],
            albums: [YMAlbum(id: albumId, title: "Album \(albumId)", coverUri: "avatars.yandex.net/get/cover/\(id)/%%")],
            coverUri: "avatars.yandex.net/get/cover/\(id)/%%"
        )
    }

    @Test("WaveSessionTasteTracker scoring priority, hard exclusion, and quick-skip filtering")
    @MainActor
    func testTasteTrackerScoringAndExclusions() {
        let tracker = WaveSessionTasteTracker()
        tracker.beginFreshSession(context: .myWaveDefault, vibe: .defaultWave)

        let trackStartedOnly = makeTrack(id: "101", title: "Background", artistId: "art1", artistName: "Artist 1")
        let trackLiked = makeTrack(id: "102", title: "Liked", artistId: "art2", artistName: "Artist 2")
        let trackMoreLike = makeTrack(id: "103", title: "Flame", artistId: "art3", artistName: "Artist 3")
        let trackQuickSkipped = makeTrack(id: "104", title: "Skipped", artistId: "art4", artistName: "Artist 4")
        let trackDisliked = makeTrack(id: "105", title: "Disliked", artistId: "art5", artistName: "Artist 5")

        tracker.recordOutcome(.started, for: trackStartedOnly)
        tracker.recordOutcome(.liked, for: trackLiked)
        tracker.recordOutcome(.moreLikeThis, for: trackMoreLike)
        tracker.recordOutcome(.started, for: trackQuickSkipped)
        tracker.recordOutcome(.skipped(playedSeconds: 4.5), for: trackQuickSkipped)
        tracker.recordOutcome(.started, for: trackDisliked)
        tracker.recordOutcome(.lessLikeThis, for: trackDisliked)

        let candidate = tracker.buildCandidateSnapshot(
            currentTrack: nil,
            queue: [],
            currentIndex: 0,
            context: .myWaveDefault,
            vibe: .defaultWave
        )

        let anchorIds = candidate.anchorTracks.map(\.id)
        #expect(anchorIds.count >= 3)
        // Highest score order: moreLikeThis (+5.5) > liked (+4.5) > started (+0.8)
        #expect(anchorIds[0] == "103")
        #expect(anchorIds[1] == "102")
        #expect(anchorIds[2] == "101")
        // Quick skip (< 15s) and lessLikeThis must NOT enter anchors
        #expect(!anchorIds.contains("104"))
        #expect(!anchorIds.contains("105"))
        // lessLikeThis adds to excludedTrackIds, quick skip alone does not
        #expect(candidate.excludedTrackIds == ["105"])
    }

    @Test("WaveSessionTasteTracker caps single-artist dominance to max 2 tracks in top-5 anchors")
    @MainActor
    func testArtistDiversificationCap() {
        let tracker = WaveSessionTasteTracker()
        tracker.beginFreshSession(context: .myWaveDefault, vibe: .defaultWave)

        // 6 strongly positive tracks from Artist A
        for i in 1...6 {
            let t = makeTrack(id: "a\(i)", title: "Dom \(i)", artistId: "dominant-A", artistName: "Dominant Artist")
            tracker.recordOutcome(.finished(playedSeconds: 120), for: t)
            tracker.recordOutcome(.liked, for: t)
        }

        // 3 positive tracks from distinct Artists B, C, D (lower score than Artist A likes, still positive)
        let tB = makeTrack(id: "b1", title: "B1", artistId: "art-B", artistName: "Artist B")
        let tC = makeTrack(id: "c1", title: "C1", artistId: "art-C", artistName: "Artist C")
        let tD = makeTrack(id: "d1", title: "D1", artistId: "art-D", artistName: "Artist D")
        tracker.recordOutcome(.finished(playedSeconds: 60), for: tB)
        tracker.recordOutcome(.finished(playedSeconds: 60), for: tC)
        tracker.recordOutcome(.finished(playedSeconds: 60), for: tD)

        let candidate = tracker.buildCandidateSnapshot(
            currentTrack: nil,
            queue: [],
            currentIndex: 0,
            context: .myWaveDefault,
            vibe: .defaultWave
        )

        #expect(candidate.anchorTracks.count == 5)
        let artistACount = candidate.anchorTracks.filter { $0.artistId == "dominant-A" }.count
        #expect(artistACount == 2)
        #expect(candidate.anchorTracks.contains { $0.id == "b1" })
        #expect(candidate.anchorTracks.contains { $0.id == "c1" })
        #expect(candidate.anchorTracks.contains { $0.id == "d1" })
    }

    @Test("SavedWavePreset remains immutable during playback drift until explicit overwritePreset")
    @MainActor
    func testPlaybackImmutabilityAndExplicitOverwrite() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SavedWavePresetStore(storageURL: url)
        let originalAnchor = SavedWaveAnchorTrack(id: "10", albumId: "1", title: "Focus 1", artistId: "a1", artistName: "Tycho")
        let created = try #require(store.createPreset(
            ownerUid: "u1",
            name: "Работа",
            icon: .briefcase,
            accentHex: "#48BC92",
            baseContextSeeds: ["genre:electronic"],
            baseContextTitle: "Электроника",
            baseFallbackStationId: "genre:electronic",
            vibe: .focus,
            anchorTracks: [originalAnchor],
            excludedTrackIds: ["999"]
        ))

        let tracker = WaveSessionTasteTracker()
        let savedContext = YMWaveContext.forSavedWave(created)
        tracker.beginSessionFromPreset(created, context: savedContext)
        #expect(tracker.hasPendingStyleDrift == false)

        // Simulate aggressive user interactions: vibe shift, likes, dislikes, skips, new finished tracks
        tracker.recordVibeChange(.calm)
        #expect(tracker.hasPendingStyleDrift == true)

        let newLike = makeTrack(id: "202", title: "Bonobo Track", artistId: "a2", artistName: "Bonobo")
        let disliked = makeTrack(id: "303", title: "Noisy Track", artistId: "a3", artistName: "Noise")
        tracker.recordOutcome(.liked, for: newLike)
        tracker.recordOutcome(.lessLikeThis, for: disliked)

        // Verify stored preset on disk and in store is 100% UNCHANGED before explicit overwrite
        let untouched = try #require(store.preset(withId: created.id))
        #expect(untouched == created)

        // Also check reloaded instance from disk (.iso8601 truncates sub-second precision)
        let reloadedBefore = SavedWavePresetStore(storageURL: url)
        reloadedBefore.loadIfNeeded(for: "u1")
        let persisted = try #require(reloadedBefore.presets.first)
        #expect(persisted.id == created.id)
        #expect(persisted.ownerUid == created.ownerUid)
        #expect(persisted.name == created.name)
        #expect(persisted.icon == created.icon)
        #expect(persisted.accentHex == created.accentHex)
        #expect(persisted.baseContextSeeds == created.baseContextSeeds)
        #expect(persisted.baseContextTitle == created.baseContextTitle)
        #expect(persisted.baseFallbackStationId == created.baseFallbackStationId)
        #expect(persisted.vibe == created.vibe)
        #expect(persisted.anchorTracks == created.anchorTracks)
        #expect(persisted.excludedTrackIds == created.excludedTrackIds)
        #expect(abs(persisted.createdAt.timeIntervalSince(created.createdAt)) < 1.0)
        #expect(abs(persisted.updatedAt.timeIntervalSince(created.updatedAt)) < 1.0)

        // Explicit overwrite persists the new vector while preserving id and createdAt
        let candidate = tracker.buildCandidateSnapshot(
            currentTrack: newLike,
            queue: [],
            currentIndex: 0,
            context: savedContext,
            vibe: .calm
        )
        let overwritten = try #require(store.overwritePreset(
            id: created.id,
            baseContextSeeds: candidate.baseContextSeeds,
            baseContextTitle: candidate.baseContextTitle,
            baseFallbackStationId: candidate.baseFallbackStationId,
            vibe: candidate.vibe,
            anchorTracks: candidate.anchorTracks,
            excludedTrackIds: candidate.excludedTrackIds
        ))

        #expect(overwritten.id == created.id)
        #expect(overwritten.createdAt == created.createdAt)
        #expect(overwritten.updatedAt >= created.updatedAt)
        #expect(overwritten.vibe == .calm)
        #expect(overwritten.anchorTracks.contains { $0.id == "202" })
        #expect(overwritten.excludedTrackIds.contains("303"))
    }

    @Test("SavedWavePresetStore persists across reloads, isolates ownerUid, and deletes cleanly")
    @MainActor
    func testStorePersistenceIsolationAndDeletion() throws {
        let url = try makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = SavedWavePresetStore(storageURL: url)
        let anchor1 = SavedWaveAnchorTrack(id: "11", title: "Work", artistName: "Artist 1")
        let anchor2 = SavedWaveAnchorTrack(id: "22", title: "Night", artistName: "Artist 2")
        let anchorOther = SavedWaveAnchorTrack(id: "33", title: "Other User", artistName: "Artist 3")

        let p1 = try #require(store.createPreset(
            ownerUid: "user-A",
            name: "Первая",
            icon: .briefcase,
            accentHex: "#F2C12E",
            baseContextSeeds: ["user:onyourwave"],
            baseContextTitle: "Моя волна",
            baseFallbackStationId: "user:onyourwave",
            vibe: .defaultWave,
            anchorTracks: [anchor1],
            excludedTrackIds: []
        ))
        // Ensure slightly later timestamp or newest-first ordering
        let p2 = try #require(store.createPreset(
            ownerUid: "user-A",
            name: "Вторая",
            icon: .moon,
            accentHex: "#7092E4",
            baseContextSeeds: ["mood:calm"],
            baseContextTitle: "Спокойное",
            baseFallbackStationId: "mood:calm",
            vibe: .calm,
            anchorTracks: [anchor2],
            excludedTrackIds: []
        ))
        let pOther = try #require(store.createPreset(
            ownerUid: "user-B",
            name: "Чужая",
            icon: .bolt,
            accentHex: "#EE444E",
            baseContextSeeds: ["user:onyourwave"],
            baseContextTitle: "Моя волна",
            baseFallbackStationId: "user:onyourwave",
            vibe: .energetic,
            anchorTracks: [anchorOther],
            excludedTrackIds: []
        ))

        // Account isolation in a fresh store instance
        let freshStoreA = SavedWavePresetStore(storageURL: url)
        freshStoreA.loadIfNeeded(for: "user-A")
        #expect(freshStoreA.presets.count == 2)
        #expect(freshStoreA.presets.map(\.id) == [p2.id, p1.id])
        #expect(!freshStoreA.presets.contains { $0.id == pOther.id })

        // Metadata rename keeps DNA intact
        freshStoreA.updateMetadata(id: p1.id, name: "Переименованная", icon: .cup, accentHex: "#48BC92")
        let renamed = try #require(freshStoreA.preset(withId: p1.id))
        #expect(renamed.name == "Переименованная")
        #expect(renamed.icon == .cup)
        #expect(renamed.anchorTracks == [anchor1])

        // Delete removes from memory and disk without affecting user-B
        freshStoreA.deletePreset(id: p2.id)
        #expect(freshStoreA.presets.count == 1)

        let freshStoreAfterDelete = SavedWavePresetStore(storageURL: url)
        freshStoreAfterDelete.loadIfNeeded(for: "user-A")
        #expect(freshStoreAfterDelete.presets.map(\.id) == [p1.id])

        freshStoreAfterDelete.resetInMemory()
        #expect(freshStoreAfterDelete.presets.isEmpty)

        freshStoreAfterDelete.loadIfNeeded(for: "user-B")
        #expect(freshStoreAfterDelete.presets.map(\.id) == [pOther.id])
    }

    @Test("YMWaveContext.forSavedWave omits generic user:onyourwave when anchors exist and prevents recursive seed growth")
    @MainActor
    func testSavedWaveContextSeedsAndNoSeedBloatAcrossOverwrites() {
        let a1 = SavedWaveAnchorTrack(id: "501", albumId: "900", title: "A1", artistId: "art1", artistName: "Artist 1")
        let a2 = SavedWaveAnchorTrack(id: "502", albumId: "901", title: "A2", artistId: "art2", artistName: "Artist 2")

        let initialPreset = SavedWavePreset(
            ownerUid: "u1",
            name: "Код ночью",
            icon: .moon,
            accentHex: "#7092E4",
            baseContextSeeds: ["genre:electronic", "user:onyourwave"],
            baseContextTitle: "Электроника",
            baseFallbackStationId: "genre:electronic",
            vibe: .focus,
            anchorTracks: [a1, a2]
        )

        let ctx1 = YMWaveContext.forSavedWave(initialPreset)
        #expect(ctx1.title == "Код ночью")
        #expect(ctx1.seeds == ["track:501", "track:502", "genre:electronic"])
        #expect(!ctx1.seeds.contains("user:onyourwave"))
        #expect(ctx1.fallbackTrackSeeds == ["track:501", "track:502"])
        #expect(ctx1.fallbackStationId == "track:501")

        // Simulate launching saved wave, listening, building new snapshot, and overwriting multiple times
        let tracker = WaveSessionTasteTracker()
        tracker.beginSessionFromPreset(initialPreset, context: ctx1)
        let extra = makeTrack(id: "503", title: "Extra", artistId: "art3", artistName: "Artist 3")
        tracker.recordOutcome(.moreLikeThis, for: extra)

        let cand2 = tracker.buildCandidateSnapshot(
            currentTrack: extra,
            queue: [],
            currentIndex: 0,
            context: ctx1,
            vibe: .focus
        )

        // baseContextSeeds must NOT contain accumulated track:* seeds!
        #expect(!cand2.baseContextSeeds.contains { $0.hasPrefix("track:") })
        #expect(cand2.baseContextSeeds.contains("genre:electronic"))
        #expect(cand2.baseContextTitle == "Электроника")

        let secondPreset = SavedWavePreset(
            id: initialPreset.id,
            ownerUid: "u1",
            name: initialPreset.name,
            icon: initialPreset.icon,
            accentHex: initialPreset.accentHex,
            baseContextSeeds: cand2.baseContextSeeds,
            baseContextTitle: cand2.baseContextTitle,
            baseFallbackStationId: cand2.baseFallbackStationId,
            vibe: cand2.vibe,
            anchorTracks: cand2.anchorTracks
        )
        let ctx2 = YMWaveContext.forSavedWave(secondPreset)
        // Strictly capped, deduplicated, zero duplicate track: or recursive seed expansion
        #expect(Set(ctx2.seeds).count == ctx2.seeds.count)
        #expect(ctx2.seeds.count <= 5)
        #expect(ctx2.seeds.contains("track:503"))
        #expect(ctx2.seeds.contains("genre:electronic"))
    }

    @Test("addedToWaveAsLiked promotes injected tracks to top anchors, clears prior exclusion, and triggers saved drift")
    @MainActor
    func testAddedToWaveAsLikedOutcomeAndQueueInjection() {
        let baseAnchor = SavedWaveAnchorTrack(id: "701", albumId: "900", title: "Base", artistId: "a1", artistName: "Base Artist")
        let preset = SavedWavePreset(
            ownerUid: "u1",
            name: "Фокус",
            baseContextSeeds: ["genre:ambient"],
            baseContextTitle: "Амбиент",
            baseFallbackStationId: "genre:ambient",
            vibe: .focus,
            anchorTracks: [baseAnchor],
            excludedTrackIds: ["702"]
        )
        let ctx = YMWaveContext.forSavedWave(preset)
        let tracker = WaveSessionTasteTracker()
        tracker.beginSessionFromPreset(preset, context: ctx)

        let injected = makeTrack(id: "702:111", title: "Chosen Fav", artistId: "a2", artistName: "Fav Artist")
        tracker.recordOutcome(.addedToWaveAsLiked, for: injected)

        #expect(tracker.hasPendingStyleDrift == true)
        #expect(!tracker.currentExcludedTrackIds.contains("702"))
        #expect(preset.excludedTrackIds == ["702"]) // Saved preset stays untouched on disk

        let candidate = tracker.buildCandidateSnapshot(
            currentTrack: nil,
            queue: [],
            currentIndex: 0,
            context: ctx,
            vibe: .focus
        )
        #expect(candidate.anchorTracks.first?.id == "702")

        // Verify AudioPlayerEngine active wave queue injection edge-cases (serial pinning, stale tail trim, dedup)
        let engine = AudioPlayerEngine()
        defer { engine.stopAndClear() }

        let cur = makeTrack(id: "800", title: "Current", artistId: "a0", artistName: "Artist 0")
        let staleRotor1 = makeTrack(id: "801", title: "Stale 1", artistId: "a1", artistName: "Artist 1")
        let staleRotor2 = makeTrack(id: "802", title: "Stale 2", artistId: "a2", artistName: "Artist 2")
        let fav1 = makeTrack(id: "901:10", title: "Fav 1", artistId: "a3", artistName: "Artist 3")
        let fav2 = makeTrack(id: "902:20", title: "Fav 2", artistId: "a4", artistName: "Artist 4")
        let dupFav1 = makeTrack(id: "901", title: "Fav 1 Dup", artistId: "a3", artistName: "Artist 3")

        // Outside wave mode -> no injection
        engine.isWaveMode = false
        engine.assignQueue([cur, staleRotor1], startingAt: 0)
        #expect(engine.injectTracksIntoActiveWave([fav1]).isEmpty)

        // Active wave mode -> injects fav1, drops staleRotor1/2, deduplicates current track while accepting its feedback
        engine.isWaveMode = true
        engine.assignQueue([cur, staleRotor1, staleRotor2], startingAt: 0)
        let res1 = engine.injectTracksIntoActiveWave([cur, fav1, dupFav1])
        #expect(res1.map(\.id) == ["800", "901:10"])
        #expect(engine.queue.map(\.id) == ["800", "901:10"])
        #expect(engine.currentIndex == 0)

        // Append simulated refreshed Rotor recommendation then inject a second track: fav1 must remain pinned!
        let newRotor = makeTrack(id: "803", title: "Refreshed Rotor", artistId: "a5", artistName: "Artist 5")
        engine.appendToQueue([newRotor])
        #expect(engine.queue.map(\.id) == ["800", "901:10", "803"])

        let res2 = engine.injectTracksIntoActiveWave([fav2])
        #expect(res2.map(\.id) == ["902:20"])
        #expect(engine.queue.map(\.id) == ["800", "901:10", "902:20"])
    }
}
