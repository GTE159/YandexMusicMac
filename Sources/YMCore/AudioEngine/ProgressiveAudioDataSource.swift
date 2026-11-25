import Foundation
import AudioToolbox
import CryptoKit
import os

// MARK: - Protocol & Format Helpers

public protocol AudioByteDataSource: AnyObject, Sendable {
    var totalSize: Int64 { get }
    var fileTypeHint: AudioFileTypeID { get }
    func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawPointer) -> (bytesRead: Int, status: OSStatus)
    func close()
}

public extension AudioByteDataSource {
    /// Maps Yandex Music stream codec identifier strings (`"flac"`, `"flac-mp4"`, `"aac"`, `"mp3"`, ...)
    /// to CoreAudio `AudioFileTypeID` hints. Note container formats (`mp4`/`m4a`) are checked before `"flac"`.
    static func audioFileTypeHint(forCodec codec: String) -> AudioFileTypeID {
        let lower = codec.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("mp4") || lower.contains("m4a") {
            return kAudioFileM4AType
        }
        if lower == "flac" || lower.contains("flac") {
            return kAudioFileFLACType
        }
        if lower.contains("aac") {
            return kAudioFileAAC_ADTSType
        }
        if lower.contains("mp3") {
            return kAudioFileMP3Type
        }
        return 0
    }
}

// MARK: - Offline Encrypted Data Source

/// Direct zero-temp-file random-access data source reading from AES-256-GCM `.ymo` offline containers.
public final class OfflineEncryptedAudioDataSource: AudioByteDataSource, @unchecked Sendable {
    public let totalSize: Int64
    public let fileTypeHint: AudioFileTypeID

    private let trackId: String
    private let key: SymmetricKey
    private let header: OfflineContainerHeader
    private let lock = NSLock()
    private var fileHandle: FileHandle?

    public init(
        fileURL: URL,
        trackId: String,
        codec: String,
        key: SymmetricKey = OfflineCrypto.audioKey
    ) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        do {
            let parsedHeader = try OfflineCrypto.readHeader(from: handle)
            self.fileHandle = handle
            self.header = parsedHeader
            self.trackId = OfflineTrackID.clean(trackId)
            self.key = key
            self.totalSize = Int64(parsedHeader.plaintextSize)
            self.fileTypeHint = Self.audioFileTypeHint(forCodec: codec)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        close()
    }

    public func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawPointer) -> (bytesRead: Int, status: OSStatus) {
        guard offset >= 0, length > 0 else { return (0, noErr) }
        guard offset < totalSize else { return (0, noErr) }

        lock.lock()
        defer { lock.unlock() }

        guard let handle = fileHandle else {
            return (0, kAudioFileNotOpenError)
        }

        let clampedLength = Int(min(Int64(length), totalSize - offset))
        guard clampedLength > 0 else { return (0, noErr) }

        var written = 0
        do {
            try OfflineCrypto.decryptRange(
                from: handle,
                header: header,
                trackId: trackId,
                key: key,
                offset: UInt64(offset),
                length: clampedLength
            ) { slice in
                let remaining = clampedLength - written
                let copyCount = min(remaining, slice.count)
                if copyCount > 0 {
                    slice.withUnsafeBytes { rawBuf in
                        if let base = rawBuf.baseAddress {
                            memcpy(buffer.advanced(by: written), base, copyCount)
                        }
                    }
                    written += copyCount
                }
                return written < clampedLength
            }
            return (written, noErr)
        } catch {
            print("[OfflineDataSource] Decrypt read failed at offset \(offset): \(error)")
            return (0, kAudioFileUnspecifiedError)
        }
    }

    public func close() {
        lock.lock()
        let handle = fileHandle
        fileHandle = nil
        lock.unlock()
        try? handle?.close()
    }
}

// MARK: - Progressive HTTP Data Source

/// Streams remote Hi-Res audio into a strictly scoped temporary file (`ym_hires_*.tmp`) while servicing
/// `AudioFileOpenWithCallbacks` reads synchronously, issuing on-demand HTTPS `Range` requests with an
/// in-memory tail window cache so MP4 `moov` headers at EOF and far seeks resolve instantaneously.
public final class ProgressiveHTTPAudioDataSource: NSObject, AudioByteDataSource, URLSessionDataDelegate, @unchecked Sendable {
    private static let tempPrefix = "ym_hires_"
    private static let tempSuffix = ".tmp"
    private static let waitWindowToleranceBytes: Int64 = 524_288
    private static let remoteCacheWindowBytes: Int = 262_144

    public var totalSize: Int64 {
        condition.lock()
        let val = _totalSize
        let downloaded = downloadedBytes
        condition.unlock()
        return val > 0 ? val : downloaded
    }

    public let fileTypeHint: AudioFileTypeID

    public var lastHTTPError: YMAPIError? {
        condition.lock()
        let err = _lastHTTPError
        condition.unlock()
        return err
    }

    private let sourceURL: URL
    private let tempFileURL: URL
    private let condition = NSCondition()
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var activeRangeTask: URLSessionDataTask?

    private var writeFD: Int32 = -1
    private var readFD: Int32 = -1

    private var _totalSize: Int64 = -1
    private var downloadedBytes: Int64 = 0
    private var isResponseValidated: Bool = false
    private var isFinished: Bool = false
    private var isClosed: Bool = false
    private var downloadError: Error?
    private var _lastHTTPError: YMAPIError?

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var didResumeOpen = false
    private let prebufferThresholdBytes: Int64 = 131_072

    // Small sliding tail/seek RAM cache (<= 256 KB) to coalesce repeated MP4 `moov` atom header reads
    private var cachedWindowStart: Int64 = -1
    private var cachedWindowData: Data = Data()

    private init(url: URL, codec: String, tempURL: URL, writeFD: Int32, readFD: Int32) {
        self.sourceURL = url
        self.fileTypeHint = Self.audioFileTypeHint(forCodec: codec)
        self.tempFileURL = tempURL
        self.writeFD = writeFD
        self.readFD = readFD

        let queue = OperationQueue()
        queue.name = "com.flow.hal.progressive.delegate"
        queue.maxConcurrentOperationCount = 1
        self.delegateQueue = queue
        super.init()
    }

    deinit {
        close()
    }

    public static func cleanupStaleTempFiles() {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(tempPrefix) && name.hasSuffix(tempSuffix) {
                try? fm.removeItem(at: item)
            }
        }
    }

    public static func open(url: URL, codec: String) async throws -> ProgressiveHTTPAudioDataSource {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempPrefix)\(UUID().uuidString)\(tempSuffix)", isDirectory: false)

        let writeFD = Darwin.open(tmpURL.path, O_CREAT | O_RDWR | O_TRUNC, S_IRUSR | S_IWUSR)
        guard writeFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Failed to create temporary Hi-Res buffer file."
            ])
        }

        let readFD = Darwin.open(tmpURL.path, O_RDONLY)
        guard readFD >= 0 else {
            let openErr = errno
            Darwin.close(writeFD)
            try? FileManager.default.removeItem(at: tmpURL)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErr), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open read descriptor for temporary Hi-Res buffer."
            ])
        }

        let dataSource = ProgressiveHTTPAudioDataSource(
            url: url,
            codec: codec,
            tempURL: tmpURL,
            writeFD: writeFD,
            readFD: readFD
        )

        do {
            try await dataSource.startAndPrebuffer()
            return dataSource
        } catch {
            dataSource.close()
            throw error
        }
    }

    private func startAndPrebuffer() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 600

        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                condition.lock()
                if isClosed {
                    condition.unlock()
                    urlSession.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.session = urlSession
                self.openContinuation = continuation

                var request = URLRequest(url: sourceURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 20

                let task = urlSession.dataTask(with: request)
                self.dataTask = task
                condition.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.close()
        }
    }

    // MARK: - AudioByteDataSource

    public func read(offset: Int64, length: Int, into buffer: UnsafeMutableRawPointer) -> (bytesRead: Int, status: OSStatus) {
        guard offset >= 0, length > 0 else { return (0, noErr) }

        condition.lock()

        guard !isClosed, readFD >= 0 else {
            condition.unlock()
            return (0, kAudioFileNotOpenError)
        }

        if _totalSize > 0 && offset >= _totalSize {
            condition.unlock()
            return (0, noErr)
        }

        let clampedLength: Int
        if _totalSize > 0 {
            clampedLength = Int(min(Int64(length), _totalSize - offset))
        } else {
            clampedLength = length
        }
        guard clampedLength > 0 else {
            condition.unlock()
            return (0, noErr)
        }

        let requiredEnd = offset + Int64(clampedLength)

        // 1. Wait briefly if the read position is ahead within the streaming horizon
        if requiredEnd > downloadedBytes &&
           offset < downloadedBytes + Self.waitWindowToleranceBytes &&
           !isFinished &&
           downloadError == nil &&
           !isClosed {
            let deadline = Date().addingTimeInterval(15.0)
            while requiredEnd > downloadedBytes &&
                  offset < downloadedBytes + Self.waitWindowToleranceBytes &&
                  !isFinished &&
                  downloadError == nil &&
                  !isClosed {
                if !condition.wait(until: deadline) {
                    break
                }
            }
        }

        guard !isClosed, readFD >= 0 else {
            condition.unlock()
            return (0, kAudioFileNotOpenError)
        }

        // 2. Serve locally downloaded bytes via thread-safe pread
        if requiredEnd <= downloadedBytes || (isFinished && offset < downloadedBytes) {
            let readable = Int(min(Int64(clampedLength), max(0, downloadedBytes - offset)))
            let fd = readFD
            condition.unlock()
            if readable <= 0 {
                return (0, noErr)
            }
            let bytes = Self.preadExact(fd: fd, buffer: buffer, count: readable, offset: offset)
            return bytes >= 0 ? (bytes, noErr) : (0, kAudioFileUnspecifiedError)
        }

        if downloadError != nil && isFinished {
            condition.unlock()
            return (0, kAudioFileUnspecifiedError)
        }

        // 3. Check cached remote window (coalesces sequential EOF MP4 moov atom reads)
        let cacheEnd = cachedWindowStart >= 0 ? cachedWindowStart + Int64(cachedWindowData.count) : -1
        if cachedWindowStart >= 0 && offset >= cachedWindowStart && offset < cacheEnd {
            let localOffset = Int(offset - cachedWindowStart)
            let availableInCache = cachedWindowData.count - localOffset
            if availableInCache >= clampedLength || (_totalSize > 0 && cachedWindowStart + Int64(cachedWindowData.count) >= _totalSize) {
                let copyCount = min(clampedLength, availableInCache)
                let slice = cachedWindowData.subdata(in: localOffset..<(localOffset + copyCount))
                condition.unlock()
                slice.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        memcpy(buffer, base, copyCount)
                    }
                }
                return (copyCount, noErr)
            }
        }

        let currentSession = session
        let knownTotal = _totalSize
        condition.unlock()

        // 4. Synchronous Range request for moov atoms at EOF or distant seeks
        let windowFetchSize = max(clampedLength, Self.remoteCacheWindowBytes)
        let rangeEnd: Int64
        if knownTotal > 0 {
            rangeEnd = min(knownTotal - 1, offset + Int64(windowFetchSize) - 1)
        } else {
            rangeEnd = offset + Int64(windowFetchSize) - 1
        }
        guard rangeEnd >= offset else {
            return (0, noErr)
        }

        return fetchRemoteRangeSync(
            urlSession: currentSession,
            rangeStart: offset,
            rangeEnd: rangeEnd,
            requestedLength: clampedLength,
            into: buffer
        )
    }

    private func fetchRemoteRangeSync(
        urlSession: URLSession?,
        rangeStart: Int64,
        rangeEnd: Int64,
        requestedLength: Int,
        into buffer: UnsafeMutableRawPointer
    ) -> (bytesRead: Int, status: OSStatus) {
        condition.lock()
        let closedNow = isClosed
        condition.unlock()
        guard !closedNow, let activeSession = urlSession else {
            return (0, kAudioFileNotOpenError)
        }

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10.0
        request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")

        let semaphore = DispatchSemaphore(value: 0)
        final class RangeResultBox: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = RangeResultBox()

        let task = activeSession.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }

        condition.lock()
        if isClosed {
            condition.unlock()
            return (0, kAudioFileNotOpenError)
        }
        activeRangeTask = task
        condition.unlock()

        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + .seconds(10))

        condition.lock()
        if activeRangeTask === task {
            activeRangeTask = nil
        }
        let closedAfter = isClosed
        condition.unlock()

        if closedAfter {
            task.cancel()
            return (0, kAudioFileNotOpenError)
        }

        if waitResult == .timedOut {
            task.cancel()
            return (0, kAudioFileUnspecifiedError)
        }

        if let http = box.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            condition.lock()
            if http.statusCode == 401 || http.statusCode == 403 {
                _lastHTTPError = .streamExpired
            } else {
                _lastHTTPError = .httpError(statusCode: http.statusCode, data: nil)
            }
            condition.unlock()
            return (0, kAudioFileUnspecifiedError)
        }

        guard box.error == nil, let fetched = box.data else {
            return (0, kAudioFileUnspecifiedError)
        }

        condition.lock()
        if !isClosed && !fetched.isEmpty {
            cachedWindowStart = rangeStart
            cachedWindowData = fetched
        }
        condition.unlock()

        let copyCount = min(requestedLength, fetched.count)
        if copyCount > 0 {
            fetched.withUnsafeBytes { rawBuf in
                if let base = rawBuf.baseAddress {
                    memcpy(buffer, base, copyCount)
                }
            }
        }
        return (copyCount, noErr)
    }

    private static func preadExact(fd: Int32, buffer: UnsafeMutableRawPointer, count: Int, offset: Int64) -> Int {
        var totalRead = 0
        while totalRead < count {
            let n = Darwin.pread(
                fd,
                buffer.advanced(by: totalRead),
                count - totalRead,
                off_t(offset + Int64(totalRead))
            )
            if n > 0 {
                totalRead += n
            } else if n == 0 {
                break
            } else {
                if errno == EINTR {
                    continue
                }
                return -1
            }
        }
        return totalRead
    }

    private func probeTotalLengthIfUnknown() {
        condition.lock()
        let alreadyKnown = _totalSize > 0
        let activeSession = session
        let closedNow = isClosed
        condition.unlock()
        guard !alreadyKnown, !closedNow, let activeSession else { return }

        var req = URLRequest(url: sourceURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8.0
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")

        let probeTask = activeSession.dataTask(with: req) { [weak self] _, response, _ in
            guard let self, let http = response as? HTTPURLResponse else { return }
            guard let contentRange = http.value(forHTTPHeaderField: "Content-Range") else { return }
            // Expected format: "bytes 0-1/12345678"
            if let slashIdx = contentRange.lastIndex(of: "/"),
               let parsedTotal = Int64(contentRange[contentRange.index(after: slashIdx)...]),
               parsedTotal > 0 {
                self.condition.lock()
                if self._totalSize <= 0 {
                    self._totalSize = parsedTotal
                    self.condition.broadcast()
                }
                self.condition.unlock()
            }
        }
        probeTask.resume()
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        condition.lock()
        if isClosed || dataTask !== self.dataTask {
            condition.unlock()
            completionHandler(.cancel)
            return
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let apiErr: YMAPIError = (http.statusCode == 401 || http.statusCode == 403)
                ? .streamExpired
                : .httpError(statusCode: http.statusCode, data: nil)
            _lastHTTPError = apiErr
            downloadError = apiErr
            isFinished = true
            let cont = takeOpenContinuationLocked()
            condition.broadcast()
            condition.unlock()
            completionHandler(.cancel)
            cont?.resume(throwing: apiErr)
            return
        }

        let expected = response.expectedContentLength
        if expected > 0 {
            _totalSize = expected
        }
        isResponseValidated = true
        let needsProbe = _totalSize <= 0
        condition.unlock()

        if needsProbe {
            probeTotalLengthIfUnknown()
        }

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        guard !isClosed, dataTask === self.dataTask, writeFD >= 0 else {
            condition.unlock()
            return
        }
        let fd = writeFD
        condition.unlock()

        let wroteAll = data.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }

        condition.lock()
        if isClosed {
            condition.unlock()
            return
        }

        if !wroteAll {
            let writeErr = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Temporary Hi-Res cache write error."
            ])
            downloadError = writeErr
            isFinished = true
            let cont = takeOpenContinuationLocked()
            condition.broadcast()
            condition.unlock()
            cont?.resume(throwing: writeErr)
            return
        }

        downloadedBytes += Int64(data.count)

        let targetPrebuffer = _totalSize > 0
            ? min(_totalSize, prebufferThresholdBytes)
            : prebufferThresholdBytes

        var contToResume: CheckedContinuation<Void, Error>?
        if isResponseValidated && downloadedBytes >= targetPrebuffer {
            contToResume = takeOpenContinuationLocked()
        }

        condition.broadcast()
        condition.unlock()

        contToResume?.resume(returning: ())
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.lock()
        guard task === self.dataTask else {
            condition.unlock()
            return
        }

        if let error {
            let nsErr = error as NSError
            if nsErr.domain != NSURLErrorDomain || nsErr.code != NSURLErrorCancelled {
                downloadError = error
            }
        } else if _totalSize <= 0 && downloadedBytes > 0 {
            _totalSize = downloadedBytes
        }

        isFinished = true
        let cont = takeOpenContinuationLocked()
        let finalError = downloadError
        let closedNow = isClosed
        let hasBytes = downloadedBytes > 0
        condition.broadcast()
        condition.unlock()

        if let cont {
            if closedNow {
                cont.resume(throwing: CancellationError())
            } else if let finalError {
                cont.resume(throwing: finalError)
            } else if !hasBytes {
                cont.resume(throwing: YMAPIError.emptyResult)
            } else {
                cont.resume(returning: ())
            }
        }
    }

    private func takeOpenContinuationLocked() -> CheckedContinuation<Void, Error>? {
        guard !didResumeOpen, let cont = openContinuation else { return nil }
        didResumeOpen = true
        openContinuation = nil
        return cont
    }

    // MARK: - Shutdown & Cleanup

    public func close() {
        condition.lock()
        if isClosed {
            condition.unlock()
            return
        }
        isClosed = true
        let mainTask = dataTask
        dataTask = nil
        let rangeTask = activeRangeTask
        activeRangeTask = nil
        let curSession = session
        session = nil
        let wFD = writeFD
        writeFD = -1
        let rFD = readFD
        readFD = -1
        cachedWindowStart = -1
        cachedWindowData.removeAll(keepingCapacity: false)
        let cont = takeOpenContinuationLocked()
        condition.broadcast()
        condition.unlock()

        cont?.resume(throwing: CancellationError())
        mainTask?.cancel()
        rangeTask?.cancel()
        curSession?.invalidateAndCancel()

        if wFD >= 0 {
            Darwin.close(wFD)
        }
        if rFD >= 0 {
            Darwin.close(rFD)
        }
        try? FileManager.default.removeItem(at: tempFileURL)
    }
}
