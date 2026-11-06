import Foundation
import AVFoundation
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
    private var unshuffledQueue: [YMTrack] = []
    public var onStartCustomWaveRequested: (@Sendable (YMWaveContext, YMWaveVibePreset?) -> Void)?

    /// Hardware audio track format details (sample rate, channel layout) from AVPlayerItem
    public private(set) var currentAudioFormatDetails: String?

    public var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    // Telemetry and UI event hooks
    public var onTrackStarted: (@Sendable (YMTrack) -> Void)?
    public var onTrackFinished: (@Sendable (YMTrack, Double) -> Void)?
    public var onTrackSkipped: (@Sendable (YMTrack, Double) -> Void)?
    public var onQueueNeedsMoreTracks: (@Sendable () -> Void)?

    // MARK: - Internal Player Resources

    private var player = AVPlayer()
    private var timeObserverToken: Any?
    private var itemEndObserver: (any NSObjectProtocol)?
    private var itemFailedObserver: (any NSObjectProtocol)?
    private var itemStatusObserver: NSKeyValueObservation?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    private var wasPlayingBeforeSleep: Bool = false
    private var hasPrefetchedNextTrack: Bool = false
    private var prefetchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var nextPreloadedStream: (trackId: String, stream: YMNetworkClient.YMResolvedAudioStream)?
    private var currentStreamRetryCount = 0
    private let maxStreamRetries = 2

    // Track played seconds for Rotor telemetry
    private var trackStartTimestamp: Date = Date()
    private var accumulatedPlayedSeconds: Double = 0
    private var lastObservedPlaybackTime: Double = 0
    private var suppressNextSkipTelemetry: Bool = false

    public init() {
        setupSystemObservers()
        setupTimeObserver()
    }

    public func cleanup() {
        cleanupObservers()
    }

    // MARK: - Queue & Playback Control

    public func setQueue(_ newQueue: [YMTrack], startingAt index: Int = 0, keepShuffle: Bool = false) {
        if !keepShuffle {
            self.isShuffleEnabled = false
            self.unshuffledQueue = [] // Не дублируем память, пока Shuffle не включен
        }
        self.queue = newQueue
        self.currentIndex = max(0, min(index, newQueue.count - 1))
        if !newQueue.isEmpty {
            playTrack(at: self.currentIndex)
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
        } else {
            appendToQueue([track])
        }
    }

    public func appendToQueue(_ tracks: [YMTrack]) {
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
    }

    public func playTrack(at index: Int) {
        guard index >= 0 && index < queue.count else { return }

        if timeObserverToken == nil {
            setupTimeObserver()
        }

        // If playing existing track, report skip event
        if let current = currentTrack, isPlaying {
            recordPlaybackSession()
            if !suppressNextSkipTelemetry {
                onTrackSkipped?(current, accumulatedPlayedSeconds)
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
        self.trackStartTimestamp = Date()
        self.progressTracker.reset()

        loadAndPlay(track: track, seekTo: nil, isInitialTrackStart: true)

        // Check if queue needs more items from Rotor / Station
        if isWaveMode && queue.count - currentIndex <= 2 {
            onQueueNeedsMoreTracks?()
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
        guard currentTrack != nil else { return }
        if timeObserverToken == nil {
            setupTimeObserver()
        }
        player.play()
        isPlaying = true
        trackStartTimestamp = Date()
        NowPlayingController.shared.updatePlaybackState(isPlaying: true, currentTime: progressTracker.currentTime)
    }

    public func pause() {
        recordPlaybackSession() // Fix: Record played seconds BEFORE setting isPlaying = false!
        player.pause()
        isPlaying = false
        NowPlayingController.shared.updatePlaybackState(isPlaying: false, currentTime: progressTracker.currentTime)
    }

    public func stopAndClear() {
        loadTask?.cancel()
        prefetchTask?.cancel()
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
        currentStreamInfo = nil
        availableStreamInfos = []
        currentAudioFormatDetails = nil
        nextPreloadedStream = nil
        progressTracker.reset()
    }

    public func next() {
        if currentIndex + 1 < queue.count {
            playTrack(at: currentIndex + 1)
        } else if isWaveMode {
            onQueueNeedsMoreTracks?()
        }
    }

    public func previous() {
        // If track played for > 3 seconds, restart current track
        if progressTracker.currentTime > 3.0 {
            seek(to: 0)
        } else if currentIndex > 0 {
            playTrack(at: currentIndex - 1)
        }
    }

    /// Relative seek in seconds (+5 or -5 seconds).
    public func seekRelative(by seconds: Double) {
        let current = progressTracker.currentTime
        let dur = progressTracker.duration
        let target = min(max(current + seconds, 0.0), dur > 0 ? dur : max(0.0, current + seconds))
        seek(to: target)
    }

    public func seek(to seconds: Double) {
        progressTracker.currentTime = seconds
        progressTracker.seekLockUntil = Date().addingTimeInterval(0.4)
        lastObservedPlaybackTime = seconds
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor [weak self] in
                guard let self = self, completed else { return }
                self.progressTracker.currentTime = seconds
                self.progressTracker.seekLockUntil = .distantPast
                self.lastObservedPlaybackTime = seconds
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
    }

    public func playShuffled(_ tracks: [YMTrack]) {
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
        }
        onQueueNeedsMoreTracks?()
    }

    public func startWave(forTrack track: YMTrack) {
        let context = YMWaveContext.forTrack(track)
        onStartCustomWaveRequested?(context, nil)
    }

    public func startWave(forPlaylist playlist: YMPlaylist, tracks: [YMTrack]) {
        let sampleIds = tracks.filter { !$0.isPlaceholder && !$0.isSpacer }.shuffled().prefix(5).map(\.id)
        let context = YMWaveContext.forPlaylist(playlist, sampleTrackIds: Array(sampleIds))
        onStartCustomWaveRequested?(context, nil)
    }

    public func startWave(forArtist artist: YMArtist) {
        let context = YMWaveContext.forArtist(artist)
        onStartCustomWaveRequested?(context, nil)
    }

    public func applyWaveTuning(_ signal: YMWaveTuningSignal, for targetTrack: YMTrack? = nil) {
        guard isWaveMode, let track = targetTrack ?? currentTrack else { return }
        switch signal {
        case .moreLikeThis:
            self.trimUpcomingWaveQueue(keepNextCount: 1)
            Task {
                try? await RotorService.shared.sendAlgorithmicMoreLikeThis(track: track)
            }
        case .lessLikeThis:
            let isCurrent = (track.id == currentTrack?.id)
            let played = isCurrent ? progressTracker.currentTime : 0
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

            var resolvedStream: YMNetworkClient.YMResolvedAudioStream?

            // Check if stream was already pre-fetched
            if !forceRefresh, let preloaded = self.nextPreloadedStream, preloaded.trackId == track.id {
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
                return
            }

            self.currentStreamInfo = stream.downloadInfo
            self.availableStreamInfos = stream.allAvailableInfos

            self.attachPlayerItem(with: stream.url, for: track, seekTo: seekSeconds, autoPlay: autoPlay, isInitialTrackStart: isInitialTrackStart)
        }
    }

    private func attachPlayerItem(with url: URL, for track: YMTrack, seekTo seekSeconds: Double?, autoPlay: Bool = true, isInitialTrackStart: Bool = true) {
        detachItemObservers()
        self.currentAudioFormatDetails = nil

        var assetOptions: [String: Any] = [:]
        if let codec = currentStreamInfo?.codec.lowercased() {
            if codec == "flac" {
                assetOptions["AVURLAssetOutOfBandMIMETypeKey"] = "audio/flac"
            } else if codec.contains("mp4") || codec == "aac" || codec == "he-aac" {
                assetOptions["AVURLAssetOutOfBandMIMETypeKey"] = "audio/mp4"
            }
        }

        let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
        let item = AVPlayerItem(asset: asset)

        self.updateAudioFormatDetails(for: item)

        // Observe end and failure notifications
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStreamFailure()
            }
        }

        self.itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                if observedItem.status == .failed {
                    print("[AudioEngine] AVPlayerItem status failed: \(String(describing: observedItem.error))")
                    self?.handleStreamFailure()
                }
            }
        }

        player.replaceCurrentItem(with: item)

        if let seekSeconds = seekSeconds, seekSeconds > 0 {
            let cmTime = CMTime(seconds: seekSeconds, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if autoPlay {
                        self.player.play()
                        self.isPlaying = true
                    } else {
                        self.isPlaying = false
                    }
                    self.isLoading = false
                    if isInitialTrackStart {
                        NowPlayingController.shared.updateTrack(track, isPlaying: autoPlay, currentTime: seekSeconds)
                        self.onTrackStarted?(track)
                    } else {
                        NowPlayingController.shared.updatePlaybackPosition(currentTime: seekSeconds, isPlaying: autoPlay)
                    }
                }
            }
        } else {
            if autoPlay {
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
            isLoading = false
            if isInitialTrackStart {
                NowPlayingController.shared.updateTrack(track, isPlaying: autoPlay)
                onTrackStarted?(track)
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
                                    self?.currentAudioFormatDetails = "\(sampleRate) Hz, \(channelStr)"
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
        next()
    }

    private func handleStreamFailure() {
        guard let track = currentTrack, currentStreamRetryCount < maxStreamRetries else {
            print("[AudioEngine] Max stream retry count reached or no current track.")
            isLoading = false
            isPlaying = false
            return
        }

        currentStreamRetryCount += 1
        let interruptedPosition = progressTracker.currentTime
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
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.currentStreamInfo = resolved.downloadInfo
                    self.availableStreamInfos = resolved.allAvailableInfos
                    self.attachPlayerItem(with: resolved.url, for: track, seekTo: interruptedPosition, autoPlay: true, isInitialTrackStart: false)
                }
            } catch {
                print("[AudioEngine] Error during stream recovery: \(error)")
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                    self?.isPlaying = false
                }
            }
        }
    }

    // MARK: - Periodic Time & Preload Observer

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPlaying else { return }

                let currentTime = CMTimeGetSeconds(time)
                guard !currentTime.isNaN && !currentTime.isInfinite else { return }

                let duration = self.player.currentItem?.duration.seconds ?? 0
                let validDuration = (!duration.isNaN && !duration.isInfinite && duration > 0) ? duration : (Double(self.currentTrack?.durationMs ?? 0) / 1000.0)

                self.progressTracker.update(currentTime: currentTime, duration: validDuration)
                self.lastObservedPlaybackTime = currentTime

                // Pre-load next track 15 seconds before the current track ends
                if validDuration > 15 && (validDuration - currentTime) <= 15 && !self.hasPrefetchedNextTrack {
                    self.triggerNextTrackPrefetch()
                }
            }
        }
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
                    self?.nextPreloadedStream = (trackId: nextTrack.id, stream: resolved)
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
        self.nextPreloadedStream = nil
        let interruptedPosition = progressTracker.currentTime
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

    public func reloadCurrentTrackStream() {
        guard let track = currentTrack else { return }
        self.nextPreloadedStream = nil
        let currentPos = progressTracker.currentTime
        let wasPlaying = self.isPlaying
        loadAndPlay(track: track, seekTo: currentPos, autoPlay: wasPlaying, forceRefresh: false, isInitialTrackStart: false)
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
                    self.play()
                }
            }
        }
    }

    private func detachItemObservers() {
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.asset.cancelLoading()
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
    }
}
