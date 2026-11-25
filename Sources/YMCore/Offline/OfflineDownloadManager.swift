import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Download Delegate with Throttled Progress

private final class OfflineURLSessionDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Entry {
        let destinationURL: URL
        let onProgress: @MainActor @Sendable (Double) -> Void
        let continuation: CheckedContinuation<URL, Error>
        var lastReportUptime: TimeInterval = 0
        var moveError: Error? = nil
        var didMoveFile: Bool = false
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    func registerAndStart(
        task: URLSessionDownloadTask,
        destinationURL: URL,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        if Task.isCancelled {
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }

        lock.lock()
        entries[task.taskIdentifier] = Entry(
            destinationURL: destinationURL,
            onProgress: onProgress,
            continuation: continuation
        )
        lock.unlock()

        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let progress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        let isComplete = totalBytesWritten >= totalBytesExpectedToWrite

        var callback: (@MainActor @Sendable (Double) -> Void)?
        lock.lock()
        if var entry = entries[downloadTask.taskIdentifier] {
            if isComplete || (now - entry.lastReportUptime) >= 0.1 {
                entry.lastReportUptime = now
                entries[downloadTask.taskIdentifier] = entry
                callback = entry.onProgress
            }
        }
        lock.unlock()

        if let callback {
            Task { @MainActor in
                callback(progress)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let entry = entries[downloadTask.taskIdentifier]
        lock.unlock()

        guard let entry else { return }

        // Synchronously relocate the temporary file before URLSession deletes it when this delegate returns.
        let destination = entry.destinationURL
        let fm = FileManager.default
        var moveErr: Error? = nil
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            moveErr = error
        }

        lock.lock()
        if var updated = entries[downloadTask.taskIdentifier] {
            updated.moveError = moveErr
            updated.didMoveFile = (moveErr == nil)
            entries[downloadTask.taskIdentifier] = updated
        }
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let entry = entries.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        guard let entry else { return }

        let cleanupTempFile = {
            try? FileManager.default.removeItem(at: entry.destinationURL)
        }

        if let error {
            cleanupTempFile()
            if (error as NSError).domain == NSURLErrorDomain &&
               (error as NSError).code == NSURLErrorCancelled {
                entry.continuation.resume(throwing: CancellationError())
            } else {
                entry.continuation.resume(throwing: error)
            }
            return
        }

        if let httpResponse = task.response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            cleanupTempFile()
            entry.continuation.resume(
                throwing: YMAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            )
            return
        }

        if let moveError = entry.moveError {
            cleanupTempFile()
            entry.continuation.resume(throwing: moveError)
            return
        }

        guard entry.didMoveFile else {
            cleanupTempFile()
            entry.continuation.resume(throwing: OfflineCryptoError.ioFailure("Download finished without audio file."))
            return
        }

        entry.continuation.resume(returning: entry.destinationURL)
    }
}

// MARK: - Offline Download Manager

/// `@MainActor @Observable` coordinator managing offline track downloads (max 2 concurrent),
/// storage quota checks, just-in-time CDN stream signing, and isolated per-track progress state.
@Observable
@MainActor
public final class OfflineDownloadManager {
    public static let shared = OfflineDownloadManager()

    public private(set) var downloadedRecords: [OfflineTrackRecord] = []
    public private(set) var downloadedTrackIds: Set<String> = []
    public private(set) var totalUsedBytes: Int64 = 0
    public private(set) var activeDownloadsCount: Int = 0
    public private(set) var pendingDownloadsCount: Int = 0
    public private(set) var lastErrorMessage: String? = nil

    @ObservationIgnored private var trackStates: [String: TrackOfflineState] = [:]
    @ObservationIgnored private var pendingQueue: [YMTrack] = []
    @ObservationIgnored private var activeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let maxConcurrentDownloads = 2
    @ObservationIgnored private var loadedOwnerUid: String? = nil
    @ObservationIgnored private var generation: UInt64 = 0

    private let store: OfflineStorageStore
    @ObservationIgnored private let downloadDelegate: OfflineURLSessionDownloadDelegate
    @ObservationIgnored private let downloadSession: URLSession

    public init(store: OfflineStorageStore = .shared) {
        self.store = store
        let delegate = OfflineURLSessionDownloadDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 2
        self.downloadDelegate = delegate
        self.downloadSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Track State & Queries

    public func state(for trackId: String) -> TrackOfflineState {
        let cleanId = OfflineTrackID.clean(trackId)
        if let existing = trackStates[cleanId] {
            return existing
        }
        let initialPhase: TrackOfflinePhase = downloadedTrackIds.contains(cleanId) ? .downloaded : .notDownloaded
        let created = TrackOfflineState(phase: initialPhase)
        trackStates[cleanId] = created
        return created
    }

    public func isDownloaded(trackId: String) -> Bool {
        downloadedTrackIds.contains(OfflineTrackID.clean(trackId))
    }

    public func downloadedTracks() -> [YMTrack] {
        downloadedRecords.map(\.track)
    }

    public func dismissError() {
        lastErrorMessage = nil
    }

    // MARK: - Index Synchronization

    private func resolvedOwnerUid() -> String? {
        if let uid = AuthService.shared.currentUser?.userId, !uid.isEmpty {
            return uid
        }
        if let saved = KeychainManager.shared.getUserId(), !saved.isEmpty {
            return saved
        }
        return nil
    }

    public func loadIndexIfNeeded() async {
        guard let ownerUid = resolvedOwnerUid() else { return }
        let currentGen = generation
        do {
            let loaded = try await store.records(for: ownerUid)
            guard generation == currentGen, resolvedOwnerUid() == ownerUid else { return }
            loadedOwnerUid = ownerUid
            applyRecords(loaded, ownerUid: ownerUid)
        } catch {
            print("[OfflineDownloadManager] Failed to load offline index: \(error.localizedDescription)")
        }
    }

    private func refreshFromStore(ownerUid: String) async {
        let currentGen = generation
        do {
            let loaded = try await store.records(for: ownerUid)
            guard generation == currentGen, resolvedOwnerUid() == ownerUid else { return }
            applyRecords(loaded, ownerUid: ownerUid)
        } catch {
            print("[OfflineDownloadManager] Failed to refresh index: \(error.localizedDescription)")
        }
    }

    private func applyRecords(_ records: [OfflineTrackRecord], ownerUid: String) {
        self.downloadedRecords = records
        let ids = Set(records.map(\.id))
        self.downloadedTrackIds = ids
        self.totalUsedBytes = records.reduce(into: Int64(0)) { $0 += $1.fileSizeBytes }

        let queuedIds = Set(pendingQueue.map { OfflineTrackID.clean($0.id) })
        for (cleanId, trackState) in trackStates {
            if activeTasks[cleanId] != nil || queuedIds.contains(cleanId) {
                continue
            }
            if ids.contains(cleanId) {
                if trackState.phase != .downloaded {
                    trackState.phase = .downloaded
                }
            } else if trackState.phase == .downloaded {
                trackState.phase = .notDownloaded
            }
        }
    }

    // MARK: - Enqueue & Queue Execution

    public func enqueueDownload(track: YMTrack) {
        enqueueDownloads(tracks: [track])
    }

    public func enqueueDownloads(tracks: [YMTrack]) {
        guard AuthService.shared.hasOfflinePlusEntitlement else {
            AudioPlayerEngine.shared.isSubscriptionRequiredPresented = true
            return
        }
        guard let uid = resolvedOwnerUid(), !uid.isEmpty else {
            lastErrorMessage = "Войдите в аккаунт Яндекс, чтобы скачивать треки."
            return
        }

        if loadedOwnerUid != uid {
            loadedOwnerUid = uid
            Task { [weak self] in
                await self?.loadIndexIfNeeded()
            }
        }

        var enqueuedCount = 0
        var existingPendingIds = Set(pendingQueue.map { OfflineTrackID.clean($0.id) })

        for track in tracks {
            guard !track.isPlaceholder, !track.isSpacer else { continue }
            let cleanId = OfflineTrackID.clean(track.id)
            guard !downloadedTrackIds.contains(cleanId),
                  activeTasks[cleanId] == nil,
                  !existingPendingIds.contains(cleanId) else {
                continue
            }
            existingPendingIds.insert(cleanId)
            pendingQueue.append(track)
            state(for: cleanId).phase = .queued
            enqueuedCount += 1
        }

        guard enqueuedCount > 0 else { return }

        lastErrorMessage = nil
        pendingDownloadsCount = pendingQueue.count
        pumpQueue()
    }

    private func pumpQueue() {
        while activeTasks.count < maxConcurrentDownloads, !pendingQueue.isEmpty {
            let limitBytes = AudioQualitySettings.shared.effectiveOfflineCacheLimitBytes
            if limitBytes > 0 {
                if totalUsedBytes >= limitBytes {
                    let limitLabel = AudioQualitySettings.shared.effectiveOfflineCacheLimitDisplay
                    for leftover in pendingQueue {
                        let id = OfflineTrackID.clean(leftover.id)
                        if activeTasks[id] == nil {
                            state(for: id).phase = downloadedTrackIds.contains(id) ? .downloaded : .notDownloaded
                        }
                    }
                    pendingQueue.removeAll()
                    pendingDownloadsCount = 0
                    lastErrorMessage = "Достигнут лимит оффлайн-кэша (\(limitLabel)). Увеличьте лимит в Настройках или удалите часть треков."
                    PlaylistsService.shared.showToast("Достигнут лимит оффлайн-кэша (\(limitLabel))")
                    return
                }
            }

            let nextTrack = pendingQueue.removeFirst()
            pendingDownloadsCount = pendingQueue.count

            let cleanId = OfflineTrackID.clean(nextTrack.id)
            guard let ownerUid = resolvedOwnerUid(), !ownerUid.isEmpty else {
                state(for: cleanId).phase = .notDownloaded
                continue
            }

            let currentGen = generation
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runDownload(track: nextTrack, cleanId: cleanId, ownerUid: ownerUid, expectedGeneration: currentGen)
            }
            activeTasks[cleanId] = task
            activeDownloadsCount = activeTasks.count
        }
    }

    private func runDownload(
        track: YMTrack,
        cleanId: String,
        ownerUid: String,
        expectedGeneration: UInt64
    ) async {
        defer {
            activeTasks.removeValue(forKey: cleanId)
            activeDownloadsCount = activeTasks.count
            if generation == expectedGeneration {
                pumpQueue()
            }
        }

        var tempAudioURL: URL? = nil
        defer {
            if let tempAudioURL {
                try? FileManager.default.removeItem(at: tempAudioURL)
            }
        }

        do {
            try Task.checkCancellation()
            state(for: cleanId).phase = .downloading(progress: 0.0)

            let preset = AudioQualitySettings.shared.offlineQualityPreset
            let codecPref = AudioQualitySettings.shared.codecPreference
            let stream = try await YMNetworkClient.shared.resolveAudioStream(
                for: cleanId,
                preset: preset,
                codecPreference: codecPref,
                forceRefresh: true
            )

            try Task.checkCancellation()

            let coverUri = track.effectiveCoverUri
            let needsCover: Bool
            if let coverUri, !coverUri.isEmpty {
                needsCover = !(await store.hasCover(for: coverUri))
            } else {
                needsCover = false
            }

            // Fetch audio stream via URLSession.download + best-effort cover/lyrics in parallel
            async let audioFileFetch = downloadFileWithProgress(from: stream.url) { [weak self] progress in
                guard let self, self.generation == expectedGeneration else { return }
                let st = self.state(for: cleanId)
                if case .downloading = st.phase {
                    st.phase = .downloading(progress: progress)
                }
            }

            async let coverFetch: Data? = {
                guard needsCover,
                      let url = YMCoverURLBuilder.buildURL(from: coverUri, size: .artwork),
                      let (cgImage, _) = await ImageDownsampler.fetchAndDownsampleCGImageWithCost(from: url, maxPixelSize: 300) else {
                    return nil
                }
                return Self.encodeJPEGData(from: cgImage, compressionQuality: 0.85)
            }()

            async let lyricsFetch: (rawLRC: String?, plainLyrics: String?) = {
                let lrc = try? await YMNetworkClient.shared.fetchTrackLyricsRawLRC(trackId: cleanId)
                if let lrc, !lrc.isEmpty {
                    return (lrc, nil)
                }
                let supplement = try? await YMNetworkClient.shared.fetchTrackSupplement(trackId: cleanId)
                let plain = supplement?.lyrics?.fullLyrics.flatMap { $0.isEmpty ? nil : $0 }
                    ?? supplement?.lyrics?.lyrics.flatMap { $0.isEmpty ? nil : $0 }
                return (nil, plain)
            }()

            let downloadedURL = try await audioFileFetch
            tempAudioURL = downloadedURL
            let (coverData, lyricsResult) = await (coverFetch, lyricsFetch)

            try Task.checkCancellation()
            guard generation == expectedGeneration else {
                throw CancellationError()
            }

            state(for: cleanId).phase = .encrypting

            _ = try await store.commitDownloadedAudio(
                tempFileURL: downloadedURL,
                track: track,
                ownerUid: ownerUid,
                downloadInfo: stream.downloadInfo,
                coverData: coverData,
                rawLRC: lyricsResult.rawLRC,
                plainLyrics: lyricsResult.plainLyrics
            )
            tempAudioURL = nil

            guard generation == expectedGeneration else {
                throw CancellationError()
            }

            await refreshFromStore(ownerUid: ownerUid)
            state(for: cleanId).phase = .downloaded
        } catch is CancellationError {
            if generation == expectedGeneration {
                state(for: cleanId).phase = downloadedTrackIds.contains(cleanId) ? .downloaded : .notDownloaded
            }
        } catch {
            if generation == expectedGeneration {
                let message = error.localizedDescription
                state(for: cleanId).phase = .failed(message)
                lastErrorMessage = "Ошибка скачивания «\(track.displayTitle)»: \(message)"
            }
        }
    }

    private func downloadFileWithProgress(
        from url: URL,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let task = downloadSession.downloadTask(with: request)
        let tempDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ym_offline_\(UUID().uuidString).tmp")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloadDelegate.registerAndStart(
                    task: task,
                    destinationURL: tempDest,
                    onProgress: onProgress,
                    continuation: continuation
                )
            }
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func encodeJPEGData(from cgImage: CGImage, compressionQuality: Double) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return buffer as Data
    }

    // MARK: - Cancellation & Deletion

    public func cancelDownload(trackId: String) {
        let cleanId = OfflineTrackID.clean(trackId)
        pendingQueue.removeAll { OfflineTrackID.clean($0.id) == cleanId }
        pendingDownloadsCount = pendingQueue.count

        if let task = activeTasks[cleanId] {
            task.cancel()
        }
        if !downloadedTrackIds.contains(cleanId) {
            state(for: cleanId).phase = .notDownloaded
        }
    }

    public func cancelAllDownloads() {
        for track in pendingQueue {
            let cleanId = OfflineTrackID.clean(track.id)
            if !downloadedTrackIds.contains(cleanId) {
                state(for: cleanId).phase = .notDownloaded
            }
        }
        pendingQueue.removeAll()
        pendingDownloadsCount = 0

        for (cleanId, task) in activeTasks {
            task.cancel()
            if !downloadedTrackIds.contains(cleanId) {
                state(for: cleanId).phase = .notDownloaded
            }
        }
    }

    public func deleteDownload(trackId: String) async {
        let cleanId = OfflineTrackID.clean(trackId)
        cancelDownload(trackId: cleanId)

        guard let ownerUid = resolvedOwnerUid(), !ownerUid.isEmpty else { return }
        do {
            try await store.removeTrack(cleanTrackId: cleanId, ownerUid: ownerUid)
            await refreshFromStore(ownerUid: ownerUid)
            state(for: cleanId).phase = .notDownloaded
        } catch {
            lastErrorMessage = "Не удалось удалить трек: \(error.localizedDescription)"
        }
    }

    public func deleteAllDownloads() async {
        cancelAllDownloads()
        guard let ownerUid = resolvedOwnerUid(), !ownerUid.isEmpty else { return }
        do {
            try await store.removeAll(for: ownerUid)
            await refreshFromStore(ownerUid: ownerUid)
            for state in trackStates.values {
                state.phase = .notDownloaded
            }
        } catch {
            lastErrorMessage = "Не удалось очистить оффлайн-кэш: \(error.localizedDescription)"
        }
    }

    public func resetForSignOut() {
        generation &+= 1
        cancelAllDownloads()
        downloadedRecords = []
        downloadedTrackIds = []
        totalUsedBytes = 0
        lastErrorMessage = nil
        loadedOwnerUid = nil
        activeDownloadsCount = 0
        pendingDownloadsCount = 0
        trackStates.removeAll()
    }
}
