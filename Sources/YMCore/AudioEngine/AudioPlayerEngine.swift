import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import AppKit
import Observation

/// Native Audio Player Engine for Yandex Music on macOS.
/// Runs strictly on @MainActor, manages AVPlayer, pre-fetches next tracks,
/// observes system power notifications and recovers from expired CDN links.
@Observable
@MainActor
public final class AudioPlayerEngine {
    public static let shared = AudioPlayerEngine()

    // MARK: - State

    public let progressTracker = PlaybackProgressTracker()
    public private(set) var currentTrack: YMTrack?
    public private(set) var isPlaying: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var queue: [YMTrack] = []
    public private(set) var currentIndex: Int = 0
    public var isWaveMode: Bool = false
    public var qualitySettings: AudioQualitySettings = .shared
    public private(set) var currentStreamInfo: YMDownloadInfo?
    public private(set) var availableStreamInfos: [YMDownloadInfo] = []

    public var activeWaveContext: YMWaveContext = .myWaveDefault
    public var activeWaveVibe: YMWaveVibePreset = .defaultWave
    public private(set) var isShuffleEnabled: Bool = false
    @ObservationIgnored private var unshuffledQueue: [YMTrack] = []
    public var onStartCustomWaveRequested: (@Sendable (YMWaveContext, YMWaveVibePreset?) -> Void)?

    /// Hardware audio track format details (sample rate, channel layout) from AVPlayerItem
    public private(set) var currentAudioFormatDetails: String?

    public var isSubscriptionRequiredPresented: Bool = false

    /// Checks whether the user has a valid subscription to stream or play offline audio.
    /// Returns true if playback can proceed, or false (triggering modal) if blocked.
    @discardableResult
    public func checkSubscriptionEligibility() -> Bool {
        if AuthService.shared.isAuthenticated {
            if let user = AuthService.shared.currentUser {
                if !user.hasActiveSubscription {
                    self.stopAndClear()
                    self.isSubscriptionRequiredPresented = true
                    return false
                }
            } else if let ent = AuthService.shared.cachedEntitlement,
                      (!ent.hasActiveSubscription || Date() >= ent.validUntil) {
                self.stopAndClear()
                self.isSubscriptionRequiredPresented = true
                return false
            }
        }
        return true
    }

    private static let volumeDefaultsKey = "ym_audio_player_volume"

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
        ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("test") ||
        ProcessInfo.processInfo.arguments.contains(where: { $0.localizedCaseInsensitiveContains("test") })
    }

    /// Reactive stored volume property (0.0...1.0) persisted in UserDefaults so keyboard shortcuts (`⌘↑` / `⌘↓`)
    /// immediately update `PlayerBarView`'s `YMSlider` without requiring pointer hover.
    public var volume: Float {
        didSet {
            let clamped = max(0, min(1, volume))
            if volume != clamped {
                volume = clamped
                return
            }
            applyEffectiveVolumes()
            if Self.isRunningTests {
                UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
            } else {
                volumePersistTask?.cancel()
                volumePersistTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
                }
            }
        }
    }

    private var actualPlaybackTime: Double {
        if player.currentItem != nil {
            let sec = CMTimeGetSeconds(player.currentTime())
            if sec.isFinite && sec >= 0 {
                return sec
            }
        }
        return max(lastObservedPlaybackTime, progressTracker.currentTime)
    }

    // Telemetry and UI event hooks
    public var onTrackStarted: (@Sendable (YMTrack) -> Void)?
    public var onTrackFinished: (@Sendable (YMTrack, Double) -> Void)?
    public var onTrackSkipped: (@Sendable (YMTrack, Double) -> Void)?
    public var onQueueNeedsMoreTracks: (@Sendable () -> Void)?
    public var onWaveTrackOutcome: (@MainActor (YMTrack, YMWaveTrackOutcome) -> Void)?

    // MARK: - Internal Player Resources & Crossfade Engine

    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private var outgoingPlayer: AVPlayer?
    @ObservationIgnored private var crossfadeTimer: Timer?
    @ObservationIgnored private var isCrossfading: Bool = false
    @ObservationIgnored private var currentFadeGain: Float = 1.0
    @ObservationIgnored private var outgoingFadeGain: Float = 0.0
    @ObservationIgnored private var crossfadeElapsedSeconds: Double = 0.0
    @ObservationIgnored private var crossfadeTotalDuration: Double = 0.0
    @ObservationIgnored private var crossfadeWaitSeconds: Double = 0.0

    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var itemEndObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var itemFailedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var itemErrorLogObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var itemStalledObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var sleepObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []

    @ObservationIgnored private var wasPlayingBeforeSleep: Bool = false
    @ObservationIgnored private var hasPrefetchedNextTrack: Bool = false
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var eqMixTask: Task<Void, Never>?
    @ObservationIgnored private var volumePersistTask: Task<Void, Never>?
    @ObservationIgnored private var nextPreloadedStream: (trackId: String, stream: YMNetworkClient.YMResolvedAudioStream, fetchedAt: Date)?
    @ObservationIgnored private var currentStreamFetchedAt: Date = .distantPast
    @ObservationIgnored private var sleepTimestamp: Date?
    @ObservationIgnored private var failedItemsHandled: Set<ObjectIdentifier> = []
    @ObservationIgnored private var currentStreamRetryCount = 0
    @ObservationIgnored private let maxStreamRetries = 2
    @ObservationIgnored private var activeOfflineLoaderDelegate: OfflineAssetResourceLoaderDelegate?
    @ObservationIgnored private var outgoingOfflineLoaderDelegate: OfflineAssetResourceLoaderDelegate?
    @ObservationIgnored private var isCurrentItemOffline: Bool = false

    // Track played seconds for Rotor telemetry
    @ObservationIgnored private var trackStartTimestamp: Date = Date()
    @ObservationIgnored private var accumulatedPlayedSeconds: Double = 0
    @ObservationIgnored private var lastObservedPlaybackTime: Double = 0
    @ObservationIgnored private var lastPublishedProgressTime: Double = 0
    @ObservationIgnored private var lastSyncedDurationTrackId: String?
    @ObservationIgnored private var lastSyncedDuration: Double = 0
    @ObservationIgnored private var suppressNextSkipTelemetry: Bool = false
    @ObservationIgnored private var pendingWaveAdvance: Bool = false

    // Paginated non-wave queue continuation (Favorites, Search, etc.)
    public typealias QueueContinuationProvider = @MainActor (_ existingTrackIds: Set<String>) async -> [YMTrack]
    @ObservationIgnored private var queueContinuationProvider: QueueContinuationProvider? = nil
    @ObservationIgnored private var queueContinuationTask: Task<Void, Never>? = nil
    @ObservationIgnored private var isFetchingQueueContinuation: Bool = false
    @ObservationIgnored private var pendingContinuationAdvance: Bool = false
    @ObservationIgnored private var queueGeneration: UInt64 = 0

    private var currentCollectionIdentifier: String {
        if isWaveMode {
            return "wave:\(activeWaveContext.fallbackStationId)"
        }
        if let albumId = currentTrack?.albums.first?.id, !albumId.isEmpty {
            return "album:\(albumId)"
        }
        return "queue"
    }

    public init() {
        if UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) != nil {
            let saved = UserDefaults.standard.float(forKey: Self.volumeDefaultsKey)
            self.volume = max(0, min(1, saved))
        } else {
            self.volume = 1.0
        }
        applyEffectiveVolumes()
        _ = EqualizerSettings.shared
        setupSystemObservers()
        setupTimeObserver()
    }

    public func cleanup() {
        cancelCrossfade(stopOutgoing: true)
        activeOfflineLoaderDelegate?.invalidate()
        activeOfflineLoaderDelegate = nil
        isCurrentItemOffline = false
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        queueContinuationTask?.cancel()
        queueContinuationTask = nil
        eqMixTask?.cancel()
        eqMixTask = nil
        volumePersistTask?.cancel()
        volumePersistTask = nil
        cleanupObservers()
    }

    private func applyEffectiveVolumes() {
        player.volume = volume * currentFadeGain
        outgoingPlayer?.volume = volume * outgoingFadeGain
    }

    private func cancelCrossfade(stopOutgoing: Bool = true) {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        isCrossfading = false
        crossfadeElapsedSeconds = 0.0
        crossfadeTotalDuration = 0.0
        crossfadeWaitSeconds = 0.0
        currentFadeGain = 1.0
        outgoingFadeGain = 0.0
        applyEffectiveVolumes()

        if stopOutgoing {
            if let outgoing = outgoingPlayer {
                outgoing.pause()
                outgoing.replaceCurrentItem(with: nil)
                outgoingPlayer = nil
            }
            outgoingOfflineLoaderDelegate?.invalidate()
            outgoingOfflineLoaderDelegate = nil
        }
    }

    private func syncNowPlayingQueue() {
        NowPlayingController.shared.updateQueueInfo(
            currentIndex: currentIndex,
            queueCount: queue.count,
            collectionIdentifier: currentCollectionIdentifier
        )
    }

    // MARK: - Queue & Playback Control

    public func setQueue(_ newQueue: [YMTrack], startingAt index: Int = 0, keepShuffle: Bool = false) {
        if newQueue.isEmpty {
            stopAndClear()
            return
        }
        guard checkSubscriptionEligibility() else { return }
        resetQueueContinuation()
        if !keepShuffle {
            self.isShuffleEnabled = false
            self.unshuffledQueue = [] // Не дублируем память, пока Shuffle не включен
        }
        self.queue = newQueue
        self.currentIndex = max(0, min(index, newQueue.count - 1))
        playTrack(at: self.currentIndex)
    }

    /// Attaches an async pagination provider for the active non-wave queue (e.g. Favorites or Search),
    /// allowing seamless playback and hotkey/button skipping beyond the initial loaded batch (50+ tracks).
    public func attachQueueContinuation(_ provider: @escaping QueueContinuationProvider) {
        self.queueContinuationProvider = provider
        self.isFetchingQueueContinuation = false
        self.pendingContinuationAdvance = false
        maybePrefetchQueueContinuation()
    }

    private func resetQueueContinuation() {
        queueGeneration &+= 1
        queueContinuationTask?.cancel()
        queueContinuationTask = nil
        queueContinuationProvider = nil
        isFetchingQueueContinuation = false
        pendingContinuationAdvance = false
    }

    private func existingQueueTrackIds() -> Set<String> {
        var ids = Set<String>(minimumCapacity: queue.count * 2)
        for track in queue {
            ids.insert(track.id)
            if let colon = track.id.firstIndex(of: ":") {
                ids.insert(String(track.id[..<colon]))
            }
        }
        return ids
    }

    private func maybePrefetchQueueContinuation() {
        guard !isWaveMode,
              queueContinuationProvider != nil,
              !queue.isEmpty,
              queue.count - currentIndex <= 8 else { return }
        triggerQueueContinuation(advanceWhenReady: false)
    }

    private func triggerQueueContinuation(advanceWhenReady: Bool) {
        guard !isWaveMode, let provider = queueContinuationProvider else { return }
        if advanceWhenReady {
            pendingContinuationAdvance = true
        }
        guard !isFetchingQueueContinuation else { return }

        isFetchingQueueContinuation = true
        let generation = queueGeneration
        let existingIds = existingQueueTrackIds()

        queueContinuationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let fetched = await provider(existingIds)
            guard !Task.isCancelled, self.queueGeneration == generation else { return }

            self.isFetchingQueueContinuation = false
            self.queueContinuationTask = nil

            let currentIds = self.existingQueueTrackIds()
            let uniqueNew = fetched.filter { track in
                if track.isPlaceholder || track.isSpacer { return false }
                if currentIds.contains(track.id) { return false }
                if let colon = track.id.firstIndex(of: ":") {
                    return !currentIds.contains(String(track.id[..<colon]))
                }
                return true
            }

            guard !uniqueNew.isEmpty else {
                // Reached the end of the paginated source
                self.queueContinuationProvider = nil
                self.pendingContinuationAdvance = false
                return
            }

            let tracksToAppend = self.isShuffleEnabled ? uniqueNew.shuffled() : uniqueNew
            self.queue.append(contentsOf: tracksToAppend)
            if self.isShuffleEnabled {
                self.unshuffledQueue.append(contentsOf: uniqueNew)
            }
            self.syncNowPlayingQueue()

            let shouldAdvance = self.pendingContinuationAdvance
            self.pendingContinuationAdvance = false
            if shouldAdvance && self.currentIndex + 1 < self.queue.count {
                self.playTrack(at: self.currentIndex + 1)
            }
        }
    }

    public func assignQueue(_ newQueue: [YMTrack], startingAt index: Int = 0) {
        setQueue(newQueue, startingAt: index)
    }

    public func addToQueue(_ tracks: [YMTrack]) {
        appendToQueue(tracks)
    }

    public func insertNext(_ track: YMTrack) {
        let insertIndex = currentIndex + 1
        if insertIndex <= queue.count {
            self.queue.insert(track, at: insertIndex)
            if !isWaveMode && isShuffleEnabled {
                self.unshuffledQueue.append(track)
            }
            syncNowPlayingQueue()
        } else {
            appendToQueue([track])
        }
    }

    public func appendToQueue(_ tracks: [YMTrack]) {
        guard !tracks.isEmpty else { return }
        let wasWaitingForWaveAdvance = pendingWaveAdvance
        pendingWaveAdvance = false

        self.queue.append(contentsOf: tracks)
        if isWaveMode && currentIndex > 40 {
            // Очищаем прослушанные треки волны раньше (порог 40 вместо 100)
            let dropCount = currentIndex - 10
            if dropCount > 0 {
                self.queue.removeFirst(dropCount)
                self.currentIndex -= dropCount
            }
        } else if !isWaveMode && isShuffleEnabled {
            self.unshuffledQueue.append(contentsOf: tracks)
        }

        syncNowPlayingQueue()

        if isWaveMode && wasWaitingForWaveAdvance && currentIndex + 1 < queue.count {
            playTrack(at: currentIndex + 1)
        }
    }

    public func playTrack(at index: Int) {
        guard checkSubscriptionEligibility() else { return }
        guard index >= 0 && index < queue.count else { return }
        cancelCrossfade(stopOutgoing: true)
        pendingWaveAdvance = false

        if timeObserverToken == nil {
            setupTimeObserver()
        }

        // If playing existing track, report skip event
        if let current = currentTrack, isPlaying {
            recordPlaybackSession()
            if !suppressNextSkipTelemetry {
                onTrackSkipped?(current, accumulatedPlayedSeconds)
                if isWaveMode {
                    onWaveTrackOutcome?(current, .skipped(playedSeconds: accumulatedPlayedSeconds))
                }
            }
        }
        suppressNextSkipTelemetry = false

        self.currentIndex = index
        let track = queue[index]
        self.currentTrack = track
        self.hasPrefetchedNextTrack = false
        self.currentStreamRetryCount = 0
        self.accumulatedPlayedSeconds = 0
        self.lastObservedPlaybackTime = 0
        self.lastPublishedProgressTime = 0
        self.trackStartTimestamp = Date()
        self.progressTracker.reset()

        loadAndPlay(track: track, seekTo: nil, isInitialTrackStart: true)

        // Check if queue needs more items from Rotor / Station or paginated non-wave source
        if isWaveMode && queue.count - currentIndex <= 2 {
            onQueueNeedsMoreTracks?()
        } else {
            maybePrefetchQueueContinuation()
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func play() {
        guard checkSubscriptionEligibility() else { return }
        guard currentTrack != nil else { return }
        if timeObserverToken == nil {
            setupTimeObserver()
        }
        if !isPlaying {
            trackStartTimestamp = Date()
        }
        player.play()
        if isCrossfading {
            outgoingPlayer?.play()
        }
        isPlaying = true
        NowPlayingController.shared.updatePlaybackState(isPlaying: true, currentTime: actualPlaybackTime)
    }

    public func pause() {
        recordPlaybackSession() // Fix: Record played seconds BEFORE setting isPlaying = false!
        player.pause()
        if isCrossfading {
            outgoingPlayer?.pause()
        }
        isPlaying = false
        NowPlayingController.shared.updatePlaybackState(isPlaying: false, currentTime: actualPlaybackTime)
    }

    public func stopAndClear() {
        cancelCrossfade(stopOutgoing: true)
        activeOfflineLoaderDelegate?.invalidate()
        activeOfflineLoaderDelegate = nil
        isCurrentItemOffline = false
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        eqMixTask?.cancel()
        eqMixTask = nil
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isLoading = false
        currentTrack = nil
        queue = []
        currentIndex = 0
        isWaveMode = false
        isShuffleEnabled = false
        unshuffledQueue = []
        activeWaveContext = .myWaveDefault
        activeWaveVibe = .defaultWave
        suppressNextSkipTelemetry = false
        pendingWaveAdvance = false
        resetQueueContinuation()
        currentStreamInfo = nil
        availableStreamInfos = []
        currentAudioFormatDetails = nil
        nextPreloadedStream = nil
        progressTracker.reset()
        NowPlayingController.shared.clearNowPlaying()
    }

    public func next() {
        if currentIndex + 1 < queue.count {
            pendingWaveAdvance = false
            pendingContinuationAdvance = false
            playTrack(at: currentIndex + 1)
        } else if isWaveMode {
            pendingWaveAdvance = true
            onQueueNeedsMoreTracks?()
        } else if queueContinuationProvider != nil {
            triggerQueueContinuation(advanceWhenReady: true)
        }
    }

    public func previous() {
        // If track played for > 3 seconds, restart current track
        if actualPlaybackTime > 3.0 {
            seek(to: 0)
        } else if currentIndex > 0 {
            playTrack(at: currentIndex - 1)
        } else if currentIndex == 0 && currentTrack != nil {
            seek(to: 0)
        }
    }

    /// Relative seek in seconds (+5 or -5 seconds).
    public func seekRelative(by seconds: Double) {
        let current = actualPlaybackTime
        let dur = progressTracker.duration
        let target = min(max(current + seconds, 0.0), dur > 0 ? dur : max(0.0, current + seconds))
        seek(to: target)
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite && seconds >= 0 else { return }
        cancelCrossfade(stopOutgoing: true)
        progressTracker.currentTime = seconds
        progressTracker.seekLockUntil = Date().addingTimeInterval(0.4)
        lastObservedPlaybackTime = seconds
        lastPublishedProgressTime = seconds
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self = self, completed else { return }
                self.progressTracker.currentTime = seconds
                self.progressTracker.seekLockUntil = .distantPast
                self.lastObservedPlaybackTime = seconds
                self.lastPublishedProgressTime = seconds
                NowPlayingController.shared.updatePlaybackPosition(seconds: seconds, isPlaying: self.isPlaying)
            }
        }
    }

    // MARK: - Shuffle Controls

    public func toggleShuffle() {
        if isWaveMode {
            isShuffleEnabled = false
            return
        }

        if isShuffleEnabled {
            // Turning shuffle OFF
            isShuffleEnabled = false
            if !unshuffledQueue.isEmpty {
                self.queue = unshuffledQueue
                if let current = currentTrack, let newIndex = queue.firstIndex(where: { $0.id == current.id }) {
                    self.currentIndex = newIndex
                }
                self.hasPrefetchedNextTrack = false
                self.nextPreloadedStream = nil
            }
        } else {
            // Turning shuffle ON
            isShuffleEnabled = true
            unshuffledQueue = queue
            guard !queue.isEmpty else { return }

            if currentIndex >= 0 && currentIndex < queue.count {
                var others = queue
                let current = others.remove(at: currentIndex)
                self.queue = [current] + others.shuffled()
                self.currentIndex = 0
            } else if let current = currentTrack {
                let others = queue.filter { $0.id != current.id }
                self.queue = [current] + others.shuffled()
                self.currentIndex = 0
            } else {
                self.queue = queue.shuffled()
                self.currentIndex = 0
            }
            self.hasPrefetchedNextTrack = false
            self.nextPreloadedStream = nil
        }
        syncNowPlayingQueue()
    }

    public func playShuffled(_ tracks: [YMTrack]) {
        guard checkSubscriptionEligibility() else { return }
        let filtered = tracks.filter { !$0.isPlaceholder && !$0.isSpacer }
        guard !filtered.isEmpty else { return }
        self.unshuffledQueue = filtered
        let shuffled = filtered.shuffled()
        self.isShuffleEnabled = true
        self.isWaveMode = false
        setQueue(shuffled, startingAt: 0, keepShuffle: true)
    }

    // MARK: - Wave Queue Trimming & Facades

    public func trimUpcomingWaveQueue(keepNextCount: Int = 1) {
        guard isWaveMode, !queue.isEmpty else { return }
        let maxIndex = min(queue.count - 1, currentIndex + max(0, keepNextCount))
        if maxIndex < queue.count - 1 {
            queue = Array(queue.prefix(maxIndex + 1))
            hasPrefetchedNextTrack = false
            nextPreloadedStream = nil
            syncNowPlayingQueue()
        }
        onQueueNeedsMoreTracks?()
    }

    public func startWave(forTrack track: YMTrack) {
        guard checkSubscriptionEligibility() else { return }
        let context = YMWaveContext.forTrack(track)
        onStartCustomWaveRequested?(context, nil)
    }

    public func startWave(forPlaylist playlist: YMPlaylist, tracks: [YMTrack]) {
        guard checkSubscriptionEligibility() else { return }
        let sampleIds = tracks.filter { !$0.isPlaceholder && !$0.isSpacer }.shuffled().prefix(5).map(\.id)
        let context = YMWaveContext.forPlaylist(playlist, sampleTrackIds: Array(sampleIds))
        onStartCustomWaveRequested?(context, nil)
    }

    public func startWave(forArtist artist: YMArtist) {
        guard checkSubscriptionEligibility() else { return }
        let context = YMWaveContext.forArtist(artist)
        onStartCustomWaveRequested?(context, nil)
    }

    public func applyWaveTuning(_ signal: YMWaveTuningSignal, for targetTrack: YMTrack? = nil) {
        guard isWaveMode, let track = targetTrack ?? currentTrack else { return }
        switch signal {
        case .moreLikeThis:
            onWaveTrackOutcome?(track, .moreLikeThis)
            self.trimUpcomingWaveQueue(keepNextCount: 1)
            Task {
                try? await RotorService.shared.sendAlgorithmicMoreLikeThis(track: track)
            }
        case .lessLikeThis:
            onWaveTrackOutcome?(track, .lessLikeThis)
            let isCurrent = (track.id == currentTrack?.id)
            let played = isCurrent ? actualPlaybackTime : 0
            if isCurrent {
                self.suppressNextSkipTelemetry = true
                self.trimUpcomingWaveQueue(keepNextCount: 2)
                self.next()
            } else {
                self.trimUpcomingWaveQueue(keepNextCount: 1)
            }
            Task {
                try? await RotorService.shared.sendAlgorithmicLessLikeThis(track: track, playedSeconds: played)
            }
        case .moreDiversity:
            let newVibe: YMWaveVibePreset = (activeWaveVibe == .unfamiliar) ? .defaultWave : .unfamiliar
            onStartCustomWaveRequested?(activeWaveContext, newVibe)
        }
    }

    // MARK: - Stream Loading & Expired Token Recovery

    private func loadAndPlay(track: YMTrack, seekTo seekSeconds: Double?, autoPlay: Bool = true, forceRefresh: Bool = false, isInitialTrackStart: Bool = true) {
        guard checkSubscriptionEligibility() else { return }
        loadTask?.cancel()
        NavigationCoordinator.shared.lyricsTrack = nil
        if timeObserverToken == nil {
            setupTimeObserver()
        }
        self.isLoading = true
        let initialDuration = Double(track.durationMs ?? 0) / 1000.0
        self.progressTracker.update(currentTime: seekSeconds ?? 0, duration: initialDuration)

        loadTask = Task { [weak self] in
            guard let self = self else { return }

            let cleanTrackId = OfflineTrackID.clean(track.id)
            if !forceRefresh,
               let uid = AuthService.shared.currentUser?.userId ?? KeychainManager.shared.getUserId(),
               let offlineRecord = await OfflineStorageStore.shared.record(for: cleanTrackId, ownerUid: uid) {
                let fileURL = await OfflineStorageStore.shared.audioFileURL(for: offlineRecord)
                if FileManager.default.fileExists(atPath: fileURL.path),
                   let built = OfflineAssetResourceLoaderDelegate.makeAsset(
                       fileURL: fileURL,
                       trackId: offlineRecord.id,
                       codec: offlineRecord.codec,
                       key: OfflineCrypto.audioKey
                   ) {
                    guard !Task.isCancelled, self.currentTrack?.id == track.id else {
                        built.delegate.invalidate()
                        return
                    }
                    let syntheticInfo = YMDownloadInfo(
                        codec: offlineRecord.codec,
                        bitrateInKbps: offlineRecord.bitrateInKbps,
                        downloadInfoUrl: built.asset.url,
                        direct: true,
                        lossless: offlineRecord.isLossless
                    )
                    self.currentStreamInfo = syntheticInfo
                    self.availableStreamInfos = [syntheticInfo]
                    self.attachPreparedAsset(
                        built.asset,
                        offlineDelegate: built.delegate,
                        for: track,
                        seekTo: seekSeconds,
                        autoPlay: autoPlay,
                        isInitialTrackStart: isInitialTrackStart
                    )
                    return
                }
            }

            var resolvedStream: YMNetworkClient.YMResolvedAudioStream?

            // Check if stream was already pre-fetched
            if !forceRefresh, let preloaded = self.nextPreloadedStream, preloaded.trackId == track.id, Date().timeIntervalSince(preloaded.fetchedAt) < 120 {
                resolvedStream = preloaded.stream
                self.nextPreloadedStream = nil
            } else {
                do {
                    resolvedStream = try await YMNetworkClient.shared.resolveAudioStream(
                        for: track.id,
                        preset: self.qualitySettings.preset,
                        codecPreference: self.qualitySettings.codecPreference,
                        forceRefresh: forceRefresh
                    )
                } catch {
                    print("[AudioEngine] Error resolving stream URL for track \(track.id): \(error)")
                }
            }

            guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }

            guard let stream = resolvedStream else {
                self.isLoading = false
                self.isPlaying = false
                self.cancelCrossfade(stopOutgoing: true)
                NowPlayingController.shared.updatePlaybackState(isPlaying: false, currentTime: self.actualPlaybackTime)
                return
            }

            self.currentStreamInfo = stream.downloadInfo
            self.availableStreamInfos = stream.allAvailableInfos

            self.attachPlayerItem(with: stream.url, for: track, seekTo: seekSeconds, autoPlay: autoPlay, isInitialTrackStart: isInitialTrackStart)
        }
    }

    private func attachPlayerItem(with url: URL, for track: YMTrack, seekTo seekSeconds: Double?, autoPlay: Bool = true, isInitialTrackStart: Bool = true) {
        var assetOptions: [String: Any] = [:]
        if let codec = currentStreamInfo?.codec.lowercased() {
            if codec == "flac" {
                assetOptions["AVURLAssetOutOfBandMIMETypeKey"] = "audio/flac"
            } else if codec.contains("mp4") || codec == "aac" || codec == "he-aac" {
                assetOptions["AVURLAssetOutOfBandMIMETypeKey"] = "audio/mp4"
            }
        }

        let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
        attachPreparedAsset(
            asset,
            offlineDelegate: nil,
            for: track,
            seekTo: seekSeconds,
            autoPlay: autoPlay,
            isInitialTrackStart: isInitialTrackStart
        )
    }

    private func attachPreparedAsset(
        _ asset: AVURLAsset,
        offlineDelegate: OfflineAssetResourceLoaderDelegate?,
        for track: YMTrack,
        seekTo seekSeconds: Double?,
        autoPlay: Bool = true,
        isInitialTrackStart: Bool = true
    ) {
        detachItemObservers()
        if let previousDelegate = activeOfflineLoaderDelegate, previousDelegate !== offlineDelegate {
            previousDelegate.invalidate()
        }
        activeOfflineLoaderDelegate = offlineDelegate
        isCurrentItemOffline = (offlineDelegate != nil)

        self.currentAudioFormatDetails = nil
        self.currentStreamFetchedAt = Date()
        self.failedItemsHandled.removeAll()

        let item = AVPlayerItem(asset: asset)

        self.updateAudioFormatDetails(for: item)

        // Observe end, failure, error-log and playback-stalled notifications
        self.itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTrackDidFinish()
            }
        }

        self.itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                self?.handleStreamFailure(for: item)
            }
        }

        self.itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            MainActor.assumeIsolated {
                if observedItem.status == .failed {
                    print("[AudioEngine] AVPlayerItem status failed: \(String(describing: observedItem.error))")
                    self?.handleStreamFailure(for: item)
                }
            }
        }

        self.itemErrorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                if let code = item.errorLog()?.events.last?.errorStatusCode {
                    let criticalCodes: Set<Int> = [401, 403, 404, 410, -1001, -1005, -1100]
                    if criticalCodes.contains(code) && (self.player.timeControlStatus != .playing || Date().timeIntervalSince(self.currentStreamFetchedAt) > 60) {
                        self.handleStreamFailure(for: item)
                    }
                }
            }
        }

        self.itemStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                if Date().timeIntervalSince(self.currentStreamFetchedAt) > 120 {
                    self.handleStreamFailure(for: item)
                }
            }
        }

        player.replaceCurrentItem(with: item)

        eqMixTask?.cancel()
        eqMixTask = nil
        if EqualizerSettings.shared.isEnabled {
            eqMixTask = Task { [weak self, weak item] in
                guard let self = self, let item = item else { return }
                if let mix = await AudioEqualizerTapBuilder.makeAudioMix(for: asset) {
                    guard !Task.isCancelled, EqualizerSettings.shared.isEnabled, self.player.currentItem === item else { return }
                    item.audioMix = mix
                }
            }
        }

        if let seekSeconds = seekSeconds, seekSeconds > 0 {
            let cmTime = CMTime(seconds: seekSeconds, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self = self, let item = item, self.player.currentItem === item else { return }
                    if autoPlay {
                        self.player.play()
                        self.isPlaying = true
                        self.trackStartTimestamp = Date()
                    } else {
                        self.isPlaying = false
                    }
                    self.isLoading = false
                    if isInitialTrackStart {
                        NowPlayingController.shared.updateTrack(
                            track,
                            isPlaying: autoPlay,
                            currentTime: seekSeconds,
                            queueIndex: self.currentIndex,
                            queueCount: self.queue.count,
                            collectionIdentifier: self.currentCollectionIdentifier
                        )
                        RemoteCommandManager.shared.updateLikeState(isLiked: LikesService.shared.isLiked(trackId: track.id))
                        self.onTrackStarted?(track)
                        if self.isWaveMode {
                            self.onWaveTrackOutcome?(track, .started)
                        }
                    } else {
                        NowPlayingController.shared.updatePlaybackPosition(currentTime: seekSeconds, isPlaying: autoPlay)
                    }
                }
            }
        } else {
            if autoPlay {
                player.play()
                isPlaying = true
                trackStartTimestamp = Date()
            } else {
                isPlaying = false
            }
            isLoading = false
            if isInitialTrackStart {
                NowPlayingController.shared.updateTrack(
                    track,
                    isPlaying: autoPlay,
                    queueIndex: currentIndex,
                    queueCount: queue.count,
                    collectionIdentifier: currentCollectionIdentifier
                )
                RemoteCommandManager.shared.updateLikeState(isLiked: LikesService.shared.isLiked(trackId: track.id))
                onTrackStarted?(track)
                if isWaveMode {
                    onWaveTrackOutcome?(track, .started)
                }
            } else {
                NowPlayingController.shared.updatePlaybackPosition(currentTime: 0, isPlaying: autoPlay)
            }
        }
    }

    private func updateAudioFormatDetails(for item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak self] in
            do {
                let tracks: [AVAssetTrack]
                if #available(macOS 13.0, *) {
                    tracks = try await asset.loadTracks(withMediaType: .audio)
                } else {
                    tracks = asset.tracks(withMediaType: .audio)
                }
                guard let audioTrack = tracks.first else { return }

                let descriptions: [Any]
                if #available(macOS 13.0, *) {
                    descriptions = try await audioTrack.load(.formatDescriptions)
                } else {
                    descriptions = audioTrack.formatDescriptions
                }

                if let desc = descriptions.first {
                    let typeRef = desc as CFTypeRef
                    if CFGetTypeID(typeRef) == CMFormatDescriptionGetTypeID() {
                        let formatDesc = desc as! CMFormatDescription
                        if CMFormatDescriptionGetMediaType(formatDesc) == kCMMediaType_Audio {
                            let basic = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
                            if let asbd = basic?.pointee {
                                let sampleRate = Int(asbd.mSampleRate)
                                let channels = asbd.mChannelsPerFrame
                                let channelStr = channels == 2 ? "Stereo" : (channels == 1 ? "Mono" : "\(channels) ch")
                                await MainActor.run { [weak self] in
                                    guard let self = self, self.player.currentItem === item else { return }
                                    self.currentAudioFormatDetails = "\(sampleRate) Hz, \(channelStr)"
                                }
                            }
                        }
                    }
                }
            } catch {
                // Ignore load errors for remote streams that haven't buffered headers yet
            }
        }
    }

    private func handleTrackDidFinish() {
        guard let track = currentTrack else { return }
        recordPlaybackSession()
        onTrackFinished?(track, accumulatedPlayedSeconds)
        if isWaveMode {
            onWaveTrackOutcome?(track, .finished(playedSeconds: accumulatedPlayedSeconds))
        }
        suppressNextSkipTelemetry = true
        next()
    }

    private func handleStreamFailure(for failedItem: AVPlayerItem? = nil) {
        if let failedItem {
            guard self.player.currentItem === failedItem else { return }
            let id = ObjectIdentifier(failedItem)
            if failedItemsHandled.contains(id) { return }
            failedItemsHandled.insert(id)
        }
        guard let track = currentTrack, currentStreamRetryCount < maxStreamRetries else {
            print("[AudioEngine] Max stream retry count reached or no current track.")
            isLoading = false
            isPlaying = false
            return
        }

        if isCurrentItemOffline {
            isCurrentItemOffline = false
            activeOfflineLoaderDelegate?.invalidate()
            activeOfflineLoaderDelegate = nil
            cancelCrossfade(stopOutgoing: true)
            currentStreamRetryCount += 1
            let interruptedPosition = actualPlaybackTime
            print("[AudioEngine] Offline stream failed at \(interruptedPosition)s. Falling back to online stream...")
            loadAndPlay(track: track, seekTo: interruptedPosition, autoPlay: true, forceRefresh: true, isInitialTrackStart: false)
            return
        }

        cancelCrossfade(stopOutgoing: true)
        currentStreamRetryCount += 1
        let interruptedPosition = actualPlaybackTime
        print("[AudioEngine] Stream failed at \(interruptedPosition)s. Retrying sign & seek (attempt \(currentStreamRetryCount))...")

        let isFlacMp4 = currentStreamInfo?.codec.lowercased().contains("flac-mp4") == true
        let shouldFallbackToMp3 = isFlacMp4 || currentStreamRetryCount >= 2

        self.nextPreloadedStream = nil
        self.loadTask?.cancel()
        self.isLoading = true

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let codecPref: YMAudioCodecPreference = shouldFallbackToMp3 ? .mp3 : self.qualitySettings.codecPreference
                let resolved = try await YMNetworkClient.shared.resolveAudioStream(
                    for: track.id,
                    preset: shouldFallbackToMp3 ? .high320 : self.qualitySettings.preset,
                    codecPreference: codecPref,
                    forceRefresh: true
                )
                guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
                self.currentStreamInfo = resolved.downloadInfo
                self.availableStreamInfos = resolved.allAvailableInfos
                self.attachPlayerItem(with: resolved.url, for: track, seekTo: interruptedPosition, autoPlay: true, isInitialTrackStart: false)
            } catch {
                print("[AudioEngine] Error during stream recovery: \(error)")
                self.isLoading = false
                self.isPlaying = false
            }
        }
    }

    // MARK: - Periodic Time & Preload Observer

    private var isHostWindowVisible: Bool {
        guard !NSApp.isHidden else { return false }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            return false
        }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, self.isPlaying else { return }

                let currentTime = CMTimeGetSeconds(time)
                guard !currentTime.isNaN && !currentTime.isInfinite else { return }

                let duration = self.player.currentItem?.duration.seconds ?? 0
                let validDuration = (!duration.isNaN && !duration.isInfinite && duration > 0) ? duration : (Double(self.currentTrack?.durationMs ?? 0) / 1000.0)

                self.lastObservedPlaybackTime = currentTime

                if self.currentStreamRetryCount > 0 && currentTime > 5.0 && self.player.timeControlStatus == .playing {
                    self.currentStreamRetryCount = 0
                }

                if let trackId = self.currentTrack?.id, (self.lastSyncedDurationTrackId != trackId || abs(self.lastSyncedDuration - validDuration) >= 0.5) {
                    self.lastSyncedDurationTrackId = trackId
                    self.lastSyncedDuration = validDuration
                    NowPlayingController.shared.updateDuration(validDuration)
                }

                // UI Progress Tracker: publish only when the host window is visible and active
                if self.isHostWindowVisible {
                    let isLyricsPresented = NavigationCoordinator.shared.isLyricsPresented
                    if isLyricsPresented || abs(currentTime - self.lastPublishedProgressTime) >= 0.35 {
                        self.progressTracker.update(currentTime: currentTime, duration: validDuration)
                        self.lastPublishedProgressTime = currentTime
                    }
                }

                let remaining = validDuration - currentTime
                let crossfadeSec = self.qualitySettings.crossfadeDuration
                let prefetchLeadTime = max(15.0, crossfadeSec + 6.0)

                // Pre-load next track well ahead of crossfade/track end
                if validDuration > prefetchLeadTime && remaining <= prefetchLeadTime && !self.hasPrefetchedNextTrack {
                    self.triggerNextTrackPrefetch()
                }

                // Trigger dual-player equal-power crossfade when configured and next track is available
                if crossfadeSec >= 0.5,
                   !self.isCrossfading,
                   validDuration > crossfadeSec + 2.0,
                   remaining <= crossfadeSec,
                   remaining > 0.25,
                   self.currentIndex + 1 < self.queue.count {
                    self.beginCrossfadeToNextTrack(duration: min(crossfadeSec, remaining))
                }
            }
        }
    }

    private func beginCrossfadeToNextTrack(duration: Double) {
        guard checkSubscriptionEligibility() else { return }
        guard !isCrossfading, currentIndex + 1 < queue.count, duration >= 0.25 else { return }

        // Report completion telemetry for the outgoing track
        if let finishingTrack = currentTrack {
            recordPlaybackSession()
            onTrackFinished?(finishingTrack, accumulatedPlayedSeconds)
            if isWaveMode {
                onWaveTrackOutcome?(finishingTrack, .finished(playedSeconds: accumulatedPlayedSeconds))
            }
        }

        // Release any previous outgoing player before swapping
        if let staleOutgoing = outgoingPlayer {
            staleOutgoing.pause()
            staleOutgoing.replaceCurrentItem(with: nil)
            outgoingPlayer = nil
        }
        outgoingOfflineLoaderDelegate?.invalidate()
        outgoingOfflineLoaderDelegate = activeOfflineLoaderDelegate
        activeOfflineLoaderDelegate = nil
        isCurrentItemOffline = false

        // Detach observers and time observer from the outgoing player WITHOUT cancelling its remaining buffer
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        detachItemObservers(cancelAssetLoading: false)

        // Move active player to outgoingPlayer and create a fresh AVPlayer for the incoming track
        outgoingPlayer = player
        player = AVPlayer()

        isCrossfading = true
        currentFadeGain = 0.0
        outgoingFadeGain = 1.0
        crossfadeElapsedSeconds = 0.0
        crossfadeTotalDuration = duration
        crossfadeWaitSeconds = 0.0
        lastPublishedProgressTime = 0
        applyEffectiveVolumes()
        setupTimeObserver()

        // Advance queue to the incoming track
        pendingWaveAdvance = false
        suppressNextSkipTelemetry = false
        currentIndex += 1
        let nextTrack = queue[currentIndex]
        currentTrack = nextTrack
        hasPrefetchedNextTrack = false
        currentStreamRetryCount = 0
        accumulatedPlayedSeconds = 0
        lastObservedPlaybackTime = 0
        trackStartTimestamp = Date()
        progressTracker.reset()

        loadAndPlay(track: nextTrack, seekTo: nil, autoPlay: true, isInitialTrackStart: true)

        if isWaveMode && queue.count - currentIndex <= 2 {
            onQueueNeedsMoreTracks?()
        } else {
            maybePrefetchQueueContinuation()
        }

        // Start 20 Hz equal-power crossfade timer (0.05s step) in .common RunLoop mode
        crossfadeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isCrossfading else { return }
                guard self.isPlaying else { return }

                let incomingReady = !self.isLoading && self.player.timeControlStatus == .playing
                if !incomingReady && self.crossfadeWaitSeconds < 3.0 {
                    self.crossfadeWaitSeconds += 0.05
                    self.outgoingFadeGain = 1.0
                    self.currentFadeGain = 0.0
                    self.applyEffectiveVolumes()
                    if let outgoing = self.outgoingPlayer, outgoing.timeControlStatus != .playing && outgoing.currentItem?.status != .readyToPlay {
                        self.cancelCrossfade(stopOutgoing: true)
                    }
                    return
                }

                self.crossfadeElapsedSeconds += 0.05
                let progress = min(1.0, self.crossfadeElapsedSeconds / max(0.05, self.crossfadeTotalDuration))
                let angle = Float(progress * Double.pi * 0.5)
                self.currentFadeGain = sin(angle)
                self.outgoingFadeGain = cos(angle)
                self.applyEffectiveVolumes()

                if progress >= 1.0 {
                    self.cancelCrossfade(stopOutgoing: true)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        crossfadeTimer = timer
    }

    private func triggerNextTrackPrefetch() {
        guard !hasPrefetchedNextTrack else { return }
        hasPrefetchedNextTrack = true

        let nextIndex = currentIndex + 1
        guard nextIndex < queue.count else {
            if isWaveMode {
                onQueueNeedsMoreTracks?()
            }
            return
        }

        let nextTrack = queue[nextIndex]
        if OfflineDownloadManager.shared.isDownloaded(trackId: nextTrack.id) {
            return
        }
        prefetchTask?.cancel()
        let preset = qualitySettings.preset
        let codec = qualitySettings.codecPreference

        prefetchTask = Task { [weak self] in
            do {
                let resolved = try await YMNetworkClient.shared.resolveAudioStream(
                    for: nextTrack.id,
                    preset: preset,
                    codecPreference: codec
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.nextPreloadedStream = (trackId: nextTrack.id, stream: resolved, fetchedAt: Date())
                }
            } catch {
                print("[AudioEngine] Background prefetch failed for next track \(nextTrack.id): \(error)")
            }
        }
    }

    // MARK: - Audio Quality Controls

    public func setAudioQualityPreset(_ preset: YMAudioQualityPreset) {
        guard qualitySettings.preset != preset else { return }
        qualitySettings.setPreset(preset)
        reloadCurrentTrackStream()
    }

    public func setCodecPreference(_ pref: YMAudioCodecPreference) {
        guard qualitySettings.codecPreference != pref else { return }
        qualitySettings.setCodecPreference(pref)
        reloadCurrentTrackStream()
    }

    public func selectStreamVariant(_ info: YMDownloadInfo) {
        guard let track = currentTrack else { return }
        cancelCrossfade(stopOutgoing: true)
        self.nextPreloadedStream = nil
        let interruptedPosition = actualPlaybackTime
        let wasPlaying = self.isPlaying
        self.isLoading = true
        loadTask?.cancel()

        loadTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let resolved = try await YMNetworkClient.shared.resolveAudioStream(
                    for: track.id,
                    specificInfo: info,
                    forceRefresh: false
                )
                guard !Task.isCancelled, self.currentTrack?.id == track.id else { return }
                self.currentStreamInfo = resolved.downloadInfo
                self.availableStreamInfos = resolved.allAvailableInfos
                self.attachPlayerItem(with: resolved.url, for: track, seekTo: interruptedPosition, autoPlay: wasPlaying, isInitialTrackStart: false)
            } catch {
                print("[AudioEngine] Error switching to stream variant \(info.displayDescription): \(error)")
                self.isLoading = false
            }
        }
    }

    public func reloadCurrentTrackStream(forceRefresh: Bool = false, forceAutoPlay: Bool? = nil) {
        guard let track = currentTrack else { return }
        cancelCrossfade(stopOutgoing: true)
        self.nextPreloadedStream = nil
        let currentPos = actualPlaybackTime
        let wasPlaying = forceAutoPlay ?? self.isPlaying
        loadAndPlay(track: track, seekTo: currentPos, autoPlay: wasPlaying, forceRefresh: forceRefresh, isInitialTrackStart: false)
    }

    private func recordPlaybackSession() {
        if isPlaying {
            let sessionPlayed = Date().timeIntervalSince(trackStartTimestamp)
            accumulatedPlayedSeconds += sessionPlayed
        }
    }

    // MARK: - System Lifecycle & Audio Route Integration

    private func setupSystemObservers() {
        // macOS Sleep / Wake notifications
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.sleepTimestamp = Date()
                self.wasPlayingBeforeSleep = self.isPlaying
                if self.isPlaying {
                    self.pause()
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.wasPlayingBeforeSleep {
                    let sleepDuration = self.sleepTimestamp.map { Date().timeIntervalSince($0) } ?? 0
                    if sleepDuration > 120 && self.currentTrack != nil && !self.isCurrentItemOffline {
                        self.reloadCurrentTrackStream(forceRefresh: true, forceAutoPlay: true)
                    } else {
                        self.play()
                    }
                }
            }
        }

        let center = NotificationCenter.default
        let occlusionObs = center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resyncPlaybackProgressIfNeeded()
            }
        }
        let deminiaturizeObs = center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resyncPlaybackProgressIfNeeded()
            }
        }
        let unhideObs = center.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resyncPlaybackProgressIfNeeded()
            }
        }
        let eqObs = center.addObserver(
            forName: .ymEqualizerEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleEqualizerEnabledChange()
            }
        }
        appObservers = [occlusionObs, deminiaturizeObs, unhideObs, eqObs]
    }

    private func resyncPlaybackProgressIfNeeded() {
        guard isPlaying, isHostWindowVisible, let currentItem = player.currentItem else { return }
        let currentTime = CMTimeGetSeconds(player.currentTime())
        guard !currentTime.isNaN && !currentTime.isInfinite else { return }
        let duration = currentItem.duration.seconds
        let validDuration = (!duration.isNaN && !duration.isInfinite && duration > 0) ? duration : (Double(currentTrack?.durationMs ?? 0) / 1000.0)
        progressTracker.update(currentTime: currentTime, duration: validDuration)
        lastPublishedProgressTime = currentTime
    }

    private func handleEqualizerEnabledChange() {
        guard let currentItem = player.currentItem else { return }
        eqMixTask?.cancel()
        eqMixTask = nil
        if EqualizerSettings.shared.isEnabled {
            if currentItem.audioMix == nil {
                let asset = currentItem.asset
                eqMixTask = Task { [weak self, weak currentItem] in
                    guard let self = self, let currentItem = currentItem else { return }
                    if let mix = await AudioEqualizerTapBuilder.makeAudioMix(for: asset) {
                        guard !Task.isCancelled, EqualizerSettings.shared.isEnabled, self.player.currentItem === currentItem else { return }
                        currentItem.audioMix = mix
                    }
                }
            }
        } else {
            currentItem.audioMix = nil
        }
    }

    private func detachItemObservers(cancelAssetLoading: Bool = true) {
        if cancelAssetLoading {
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        if let endObs = itemEndObserver {
            NotificationCenter.default.removeObserver(endObs)
            itemEndObserver = nil
        }
        if let failObs = itemFailedObserver {
            NotificationCenter.default.removeObserver(failObs)
            itemFailedObserver = nil
        }
        if let errObs = itemErrorLogObserver {
            NotificationCenter.default.removeObserver(errObs)
            itemErrorLogObserver = nil
        }
        if let stallObs = itemStalledObserver {
            NotificationCenter.default.removeObserver(stallObs)
            itemStalledObserver = nil
        }
    }

    private func cleanupObservers() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        detachItemObservers()
        if let sleepObs = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObs)
            sleepObserver = nil
        }
        if let wakeObs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObs)
            wakeObserver = nil
        }
        for obs in appObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        appObservers.removeAll()
    }
}
