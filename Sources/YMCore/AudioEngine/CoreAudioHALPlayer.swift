import Foundation
import AudioToolbox
import AudioUnit
import CoreAudio
import os

/// Decodes compressed/lossless audio frames (`ExtAudioFileWrapAudioFileID` + `AudioFileOpenWithCallbacks`)
/// into a lock-light `PCMStreamRingBuffer` consumed by CoreAudio `AUHAL` (`kAudioUnitSubType_HALOutput`).
/// Provides Sample Rate switching, Hog Mode exclusive capture, integer format negotiation,
/// 5 ms anti-zipper gain ramps, and bit-perfect unity-gain passthrough when `bypassVolume == true`.
@MainActor
public final class CoreAudioHALPlayer {

    // MARK: - Public Metadata & Callbacks

    public struct StreamMetadata: Sendable {
        public let sourceSampleRate: Double
        public let sourceBitDepth: Int
        public let sourceChannels: Int
        public let durationSeconds: Double
        public let codecDisplay: String
        public let deviceSession: AcquiredDeviceSession
    }

    public var onTimeUpdate: (@MainActor (Double, Double) -> Void)?
    public var onTrackFinished: (@MainActor () -> Void)?
    public var onPlaybackError: (@MainActor (Error) -> Void)?

    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var activeMetadata: StreamMetadata?

    public var volume: Float = 1.0 {
        didSet {
            renderContext?.setTargetVolume(max(0.0, min(1.0, volume)))
        }
    }

    // MARK: - Internal Session State

    private var sessionToken: UInt64 = 0
    private var openSession: OpenAudioResources?
    private var renderContext: HALRenderContext?
    private var audioUnit: AudioComponentInstance?
    private var progressTimer: Timer?

    private var currentPreferredDeviceUID: String = ""
    private var currentSwitchSampleRate: Bool = false
    private var currentRequestHogMode: Bool = false
    private var currentBypassVolume: Bool = false
    private var pausedPositionSeconds: Double = 0
    private var lastReportedSeekSeconds: Double?

    public init() {}

    // MARK: - Loading & Lifecycle

    public func loadAndStart(
        source: AudioByteDataSource,
        codec: String,
        seekTo: Double?,
        autoPlay: Bool,
        preferredDeviceUID: String,
        switchSampleRate: Bool,
        requestHogMode: Bool,
        bypassVolume: Bool
    ) async throws -> StreamMetadata {
        stopAndRelease()
        sessionToken &+= 1
        let activeToken = sessionToken

        self.currentPreferredDeviceUID = preferredDeviceUID
        self.currentSwitchSampleRate = switchSampleRate
        self.currentRequestHogMode = requestHogMode
        self.currentBypassVolume = bypassVolume

        // 1. Open container & ExtAudioFile off MainActor so network headers / moov atoms never stall UI
        let opened = try await Task.detached(priority: .userInitiated) {
            try OpenAudioResources.open(source: source, codec: codec)
        }.value

        if Task.isCancelled || sessionToken != activeToken {
            opened.disposeAll()
            throw CancellationError()
        }

        // 2. Acquire hardware output device cleanly
        guard let deviceSession = await CoreAudioDeviceManager.shared.acquireDevice(
            preferredUID: preferredDeviceUID,
            sourceSampleRate: opened.sourceSampleRate,
            sourceBitDepth: opened.sourceBitDepth,
            switchSampleRate: switchSampleRate,
            requestHogMode: requestHogMode
        ) else {
            opened.disposeAll()
            throw NSError(domain: "com.flow.hal", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Не найдено доступное устройство аудиовывода."
            ])
        }

        if Task.isCancelled || sessionToken != activeToken {
            CoreAudioDeviceManager.shared.releaseDevice(deviceSession)
            opened.disposeAll()
            throw CancellationError()
        }

        let effectiveBypass = deviceSession.hogModeAcquired && bypassVolume
        let startSeconds = max(0.0, min(seekTo ?? 0.0, opened.durationSeconds > 0 ? opened.durationSeconds : Double.greatestFiniteMagnitude))

        let metadata = StreamMetadata(
            sourceSampleRate: opened.sourceSampleRate,
            sourceBitDepth: opened.sourceBitDepth,
            sourceChannels: opened.sourceChannels,
            durationSeconds: opened.durationSeconds,
            codecDisplay: Self.formatCodecDisplay(codec: codec),
            deviceSession: deviceSession
        )

        self.openSession = opened
        self.activeMetadata = metadata
        self.duration = opened.durationSeconds
        self.currentTime = startSeconds
        self.pausedPositionSeconds = startSeconds
        self.lastReportedSeekSeconds = nil

        if !autoPlay {
            // Prepare client format at target sample rate, seek, then immediately release Hog Mode while paused
            do {
                try opened.configureClientFormat(sampleRate: deviceSession.actualSampleRate)
                opened.seekSync(toSeconds: startSeconds)
            } catch {
                CoreAudioDeviceManager.shared.releaseDevice(deviceSession)
                opened.disposeAll()
                self.openSession = nil
                self.activeMetadata = nil
                throw error
            }
            CoreAudioDeviceManager.shared.releaseDevice(deviceSession)
            self.isPlaying = false
            return metadata
        }

        do {
            try await configureAndStartPipeline(
                opened: opened,
                deviceSession: deviceSession,
                startSeconds: startSeconds,
                bypassVolume: effectiveBypass,
                token: activeToken
            )
            return metadata
        } catch {
            stopAndRelease()
            throw error
        }
    }

    public func play() async throws {
        guard !isPlaying else { return }
        guard let opened = openSession, let existingMeta = activeMetadata else { return }

        sessionToken &+= 1
        let activeToken = sessionToken

        guard let deviceSession = await CoreAudioDeviceManager.shared.acquireDevice(
            preferredUID: currentPreferredDeviceUID,
            sourceSampleRate: existingMeta.sourceSampleRate,
            sourceBitDepth: existingMeta.sourceBitDepth,
            switchSampleRate: currentSwitchSampleRate,
            requestHogMode: currentRequestHogMode
        ) else {
            throw NSError(domain: "com.flow.hal", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Не найдено устройство аудиовывода для возобновления."
            ])
        }

        guard sessionToken == activeToken, openSession === opened else {
            CoreAudioDeviceManager.shared.releaseDevice(deviceSession)
            return
        }

        let updatedMeta = StreamMetadata(
            sourceSampleRate: existingMeta.sourceSampleRate,
            sourceBitDepth: existingMeta.sourceBitDepth,
            sourceChannels: existingMeta.sourceChannels,
            durationSeconds: existingMeta.durationSeconds,
            codecDisplay: existingMeta.codecDisplay,
            deviceSession: deviceSession
        )
        self.activeMetadata = updatedMeta

        let effectiveBypass = deviceSession.hogModeAcquired && currentBypassVolume
        let resumeAt = pausedPositionSeconds
        try await configureAndStartPipeline(
            opened: opened,
            deviceSession: deviceSession,
            startSeconds: resumeAt,
            bypassVolume: effectiveBypass,
            token: activeToken
        )
    }

    public func pause() {
        guard let opened = openSession else {
            isPlaying = false
            return
        }

        let capturedPos: Double
        if let ctx = renderContext {
            capturedPos = ctx.currentPlaybackSeconds()
            if isPlaying && audioUnit != nil {
                ctx.triggerFadeOutAndWait(timeoutMs: 18)
            }
        } else {
            capturedPos = pausedPositionSeconds
        }

        pausedPositionSeconds = capturedPos
        currentTime = capturedPos
        isPlaying = false

        teardownAUHALAndWorker(opened: opened)

        if let meta = activeMetadata {
            CoreAudioDeviceManager.shared.releaseDevice(meta.deviceSession)
        }
    }

    public func seek(to seconds: Double) {
        guard seconds.isFinite && seconds >= 0 else { return }
        let clamped = duration > 0 ? min(seconds, duration) : seconds

        pausedPositionSeconds = clamped
        currentTime = clamped
        lastReportedSeekSeconds = clamped

        guard isPlaying, let opened = openSession, let ctx = renderContext else {
            return
        }

        let newGeneration = opened.ringBuffer.reset()
        ctx.resetForSeek(startSeconds: clamped, triggerFadeIn: true)
        opened.enqueueSeekAndDecode(toSeconds: clamped, expectedGeneration: newGeneration)
    }

    public func stopAndRelease() {
        sessionToken &+= 1
        isPlaying = false
        currentTime = 0
        duration = 0
        pausedPositionSeconds = 0
        lastReportedSeekSeconds = nil

        if let opened = openSession {
            if let ctx = renderContext, audioUnit != nil {
                ctx.triggerFadeOutAndWait(timeoutMs: 18)
            }
            // Interrupt any in-flight HTTP Range/wait calls before stopping decode thread
            opened.dataSource.close()
            teardownAUHALAndWorker(opened: opened)
            opened.disposeAll()
            openSession = nil
        }

        if let meta = activeMetadata {
            CoreAudioDeviceManager.shared.releaseDevice(meta.deviceSession)
            activeMetadata = nil
        }
    }

    // MARK: - Internal Pipeline Bring-up & Teardown

    private func configureAndStartPipeline(
        opened: OpenAudioResources,
        deviceSession: AcquiredDeviceSession,
        startSeconds: Double,
        bypassVolume: Bool,
        token: UInt64
    ) async throws {
        teardownAUHALAndWorker(opened: opened)

        let rate = deviceSession.actualSampleRate
        let gen = opened.ringBuffer.reset()

        // Configure converter & perform prebuffer seek/decode off MainActor
        try await Task.detached(priority: .userInitiated) {
            try opened.configureClientFormat(sampleRate: rate)
            opened.seekSync(toSeconds: startSeconds)
            opened.prefillRingBuffer(frames: min(32_768, Int(rate * 0.35)), generation: gen)
        }.value

        guard sessionToken == token, openSession === opened else {
            throw CancellationError()
        }

        let ctx = HALRenderContext(
            ringBuffer: opened.ringBuffer,
            sampleRate: rate,
            initialSeconds: startSeconds,
            targetVolume: volume,
            bypassVolume: bypassVolume
        )
        ctx.onEOFReached = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sessionToken == token, self.isPlaying else { return }
                    self.handleEOF()
                }
            }
        }
        self.renderContext = ctx

        opened.onDecodeError = { [weak self] err in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.sessionToken == token else { return }
                    let reportedErr = (opened.dataSource as? ProgressiveHTTPAudioDataSource)?.lastHTTPError ?? err
                    self.stopAndRelease()
                    self.onPlaybackError?(reportedErr)
                }
            }
        }
        opened.startDecodeWorker(generation: gen)

        let au = try Self.createAndStartAUHAL(
            deviceID: deviceSession.deviceID,
            sampleRate: rate,
            renderContext: ctx
        )
        self.audioUnit = au
        self.isPlaying = true
        startProgressTimer(token: token)
    }

    private func teardownAUHALAndWorker(opened: OpenAudioResources) {
        progressTimer?.invalidate()
        progressTimer = nil

        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }

        opened.stopDecodeWorker()

        if let ctx = renderContext {
            ctx.onEOFReached = nil
            renderContext = nil
        }
    }

    private func startProgressTimer(token: UInt64) {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sessionToken == token, self.isPlaying, let ctx = self.renderContext else {
                    return
                }
                let rawSec = ctx.currentPlaybackSeconds()
                let clamped = self.duration > 0 ? min(rawSec, self.duration) : rawSec
                self.currentTime = clamped
                self.onTimeUpdate?(clamped, self.duration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func handleEOF() {
        let finalPos = duration > 0 ? duration : currentTime
        currentTime = finalPos
        pausedPositionSeconds = finalPos
        onTimeUpdate?(finalPos, duration)
        stopAndRelease()
        onTrackFinished?()
    }

    private static func createAndStartAUHAL(
        deviceID: AudioDeviceID,
        sampleRate: Double,
        renderContext: HALRenderContext
    ) throws -> AudioComponentInstance {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement), userInfo: [
                NSLocalizedDescriptionKey: "AUHAL AudioComponent не найден."
            ])
        }

        var unitOpt: AudioComponentInstance?
        let newStatus = AudioComponentInstanceNew(comp, &unitOpt)
        guard newStatus == noErr, let unit = unitOpt else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(newStatus), userInfo: [
                NSLocalizedDescriptionKey: "Не удалось создать AUHAL AudioUnit (\(newStatus))."
            ])
        }

        var shouldDispose = true
        defer {
            if shouldDispose {
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
            }
        }

        var enableOutput: UInt32 = 1
        var status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &enableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var disableInput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &disableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var devID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var streamFormat = OpenAudioResources.makeStereoFloat32ASBD(sampleRate: sampleRate)
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: halRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(renderContext).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        shouldDispose = false
        return unit
    }

    private static func formatCodecDisplay(codec: String) -> String {
        let lower = codec.lowercased()
        if lower == "flac" || lower.contains("flac") {
            return "FLAC"
        }
        if lower.contains("aac") {
            return "AAC"
        }
        if lower.contains("mp3") {
            return "MP3"
        }
        return codec.uppercased()
    }
}

// MARK: - Open AudioFile & Decode Worker Container

private final class OpenAudioResources: @unchecked Sendable {
    let dataSource: AudioByteDataSource
    let audioFile: AudioFileID
    let extAudioFile: ExtAudioFileRef
    let callbackContextRef: Unmanaged<AudioFileCallbackContext>
    let ringBuffer: PCMStreamRingBuffer

    let sourceSampleRate: Double
    let sourceBitDepth: Int
    let sourceChannels: Int
    let durationSeconds: Double

    var onDecodeError: (@Sendable (Error) -> Void)?

    private var configuredClientSampleRate: Double = 0
    private let workerCondition = NSCondition()
    private var workerShouldStop: Bool = false
    private var workerRunning: Bool = false
    private var workerThread: Thread?
    private var pendingSeekSeconds: Double?
    private var activeGeneration: UInt64 = 0

    private init(
        dataSource: AudioByteDataSource,
        audioFile: AudioFileID,
        extAudioFile: ExtAudioFileRef,
        callbackContextRef: Unmanaged<AudioFileCallbackContext>,
        sourceSampleRate: Double,
        sourceBitDepth: Int,
        sourceChannels: Int,
        durationSeconds: Double
    ) {
        self.dataSource = dataSource
        self.audioFile = audioFile
        self.extAudioFile = extAudioFile
        self.callbackContextRef = callbackContextRef
        self.ringBuffer = PCMStreamRingBuffer(capacityFrames: 131_072, channelCount: 2)
        self.sourceSampleRate = sourceSampleRate
        self.sourceBitDepth = sourceBitDepth
        self.sourceChannels = sourceChannels
        self.durationSeconds = durationSeconds
    }

    static func open(source: AudioByteDataSource, codec: String) throws -> OpenAudioResources {
        let ctx = AudioFileCallbackContext(source: source)
        let ctxRef = Unmanaged.passRetained(ctx)

        var audioFileOpt: AudioFileID?
        let hintsToTry: [AudioFileTypeID] = source.fileTypeHint != 0 ? [source.fileTypeHint, 0] : [0]

        var openStatus: OSStatus = kAudioFileUnspecifiedError
        for hint in hintsToTry {
            openStatus = AudioFileOpenWithCallbacks(
                ctxRef.toOpaque(),
                halAudioFileReadProc,
                nil,
                halAudioFileGetSizeProc,
                nil,
                hint,
                &audioFileOpt
            )
            if openStatus == noErr, audioFileOpt != nil {
                break
            }
        }

        guard openStatus == noErr, let audioFile = audioFileOpt else {
            ctxRef.release()
            if let httpErr = (source as? ProgressiveHTTPAudioDataSource)?.lastHTTPError {
                throw httpErr
            }
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(openStatus), userInfo: [
                NSLocalizedDescriptionKey: "AudioFileOpenWithCallbacks error (\(openStatus))"
            ])
        }

        var extFileOpt: ExtAudioFileRef?
        let wrapStatus = ExtAudioFileWrapAudioFileID(audioFile, false, &extFileOpt)
        guard wrapStatus == noErr, let extFile = extFileOpt else {
            AudioFileClose(audioFile)
            ctxRef.release()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(wrapStatus), userInfo: [
                NSLocalizedDescriptionKey: "ExtAudioFileWrapAudioFileID error (\(wrapStatus))"
            ])
        }

        var fileFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileDataFormat, &fmtSize, &fileFormat)

        let srcRate = fileFormat.mSampleRate > 0 ? fileFormat.mSampleRate : 44_100.0
        let srcChannels = max(1, Int(fileFormat.mChannelsPerFrame))
        let srcBitDepth = resolveSourceBitDepth(from: fileFormat, codec: codec)

        var lengthFrames: Int64 = 0
        var lenSize = UInt32(MemoryLayout<Int64>.size)
        var durSec: Double = 0
        if ExtAudioFileGetProperty(extFile, kExtAudioFileProperty_FileLengthFrames, &lenSize, &lengthFrames) == noErr,
           lengthFrames > 0, srcRate > 0 {
            durSec = Double(lengthFrames) / srcRate
        } else {
            var estimated: Float64 = 0
            var estSize = UInt32(MemoryLayout<Float64>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyEstimatedDuration, &estSize, &estimated) == noErr,
               estimated > 0 {
                durSec = Double(estimated)
            }
        }

        return OpenAudioResources(
            dataSource: source,
            audioFile: audioFile,
            extAudioFile: extFile,
            callbackContextRef: ctxRef,
            sourceSampleRate: srcRate,
            sourceBitDepth: srcBitDepth,
            sourceChannels: srcChannels,
            durationSeconds: durSec
        )
    }

    static func makeStereoFloat32ASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerSample * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: bytesPerSample * 8,
            mReserved: 0
        )
    }

    func configureClientFormat(sampleRate: Double) throws {
        if abs(configuredClientSampleRate - sampleRate) < 0.5 {
            return
        }

        var clientFormat = Self.makeStereoFloat32ASBD(sampleRate: sampleRate)
        let status = ExtAudioFileSetProperty(
            extAudioFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to configure ExtAudioFile client format (\(status))."
            ])
        }

        if abs(sourceSampleRate - sampleRate) >= 1.0 {
            var converter: AudioConverterRef?
            var convSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
            if ExtAudioFileGetProperty(extAudioFile, kExtAudioFileProperty_AudioConverter, &convSize, &converter) == noErr,
               let converter {
                var quality = UInt32(kAudioConverterQuality_Max)
                AudioConverterSetProperty(
                    converter,
                    kAudioConverterSampleRateConverterQuality,
                    UInt32(MemoryLayout<UInt32>.size),
                    &quality
                )
                var emptyConfigPtr: UnsafeRawPointer? = nil
                _ = withUnsafePointer(to: &emptyConfigPtr) { ptr in
                    ExtAudioFileSetProperty(
                        extAudioFile,
                        kExtAudioFileProperty_ConverterConfig,
                        UInt32(MemoryLayout<UnsafeRawPointer?>.size),
                        ptr
                    )
                }
            }
        }

        configuredClientSampleRate = sampleRate
    }

    func seekSync(toSeconds seconds: Double) {
        let clamped = durationSeconds > 0 ? min(max(0.0, seconds), durationSeconds) : max(0.0, seconds)
        let targetFileFrame = Int64((clamped * sourceSampleRate).rounded())
        _ = ExtAudioFileSeek(extAudioFile, max(0, targetFileFrame))
    }

    func prefillRingBuffer(frames targetFrames: Int, generation: UInt64) {
        let decodeChunkFrames = 4096
        let tempBuf = UnsafeMutablePointer<Float>.allocate(capacity: decodeChunkFrames * 2)
        defer { tempBuf.deallocate() }

        var accumulated = 0
        while accumulated < targetFrames {
            let toDecode = min(decodeChunkFrames, targetFrames - accumulated)
            var frameCount = UInt32(toDecode)
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(toDecode * 2 * MemoryLayout<Float>.size),
                    mData: tempBuf
                )
            )
            let status = ExtAudioFileRead(extAudioFile, &frameCount, &abl)
            if status != noErr {
                break
            }
            if frameCount == 0 {
                ringBuffer.markEOF(generation: generation)
                break
            }
            let written = ringBuffer.write(from: tempBuf, frameCount: Int(frameCount), generation: generation)
            accumulated += written
            if written == 0 {
                break
            }
        }
    }

    func startDecodeWorker(generation: UInt64) {
        stopDecodeWorker()

        workerCondition.lock()
        workerShouldStop = false
        workerRunning = true
        pendingSeekSeconds = nil
        activeGeneration = generation
        workerCondition.unlock()

        let thread = Thread { [weak self] in
            self?.runDecodeLoop()
        }
        thread.name = "com.flow.hal.decode"
        thread.qualityOfService = .userInitiated
        workerThread = thread
        thread.start()
    }

    func enqueueSeekAndDecode(toSeconds seconds: Double, expectedGeneration: UInt64) {
        workerCondition.lock()
        pendingSeekSeconds = seconds
        activeGeneration = expectedGeneration
        workerCondition.broadcast()
        workerCondition.unlock()
    }

    func stopDecodeWorker() {
        workerCondition.lock()
        workerShouldStop = true
        workerCondition.broadcast()
        while workerRunning {
            workerCondition.wait(until: Date().addingTimeInterval(0.05))
        }
        workerThread = nil
        workerCondition.unlock()
    }

    func disposeAll() {
        stopDecodeWorker()
        dataSource.close()
        ExtAudioFileDispose(extAudioFile)
        AudioFileClose(audioFile)
        callbackContextRef.release()
    }

    private func runDecodeLoop() {
        let chunkFrames = 4096
        let decodeBuf = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * 2)
        defer {
            decodeBuf.deallocate()
            workerCondition.lock()
            workerRunning = false
            workerCondition.broadcast()
            workerCondition.unlock()
        }

        var reachedEOF = false

        while true {
            workerCondition.lock()
            if workerShouldStop {
                workerCondition.unlock()
                return
            }

            if let seekTarget = pendingSeekSeconds {
                pendingSeekSeconds = nil
                let gen = activeGeneration
                workerCondition.unlock()
                seekSync(toSeconds: seekTarget)
                reachedEOF = false
                // Immediately push first frames after seek under new generation
                _ = decodeOneChunk(into: decodeBuf, maxFrames: chunkFrames, generation: gen, reachedEOF: &reachedEOF)
                continue
            }

            let gen = activeGeneration
            let freeFrames = ringBuffer.freeFrames

            if reachedEOF || freeFrames < chunkFrames {
                workerCondition.wait(until: Date().addingTimeInterval(0.012))
                workerCondition.unlock()
                continue
            }
            workerCondition.unlock()

            let ok = decodeOneChunk(into: decodeBuf, maxFrames: chunkFrames, generation: gen, reachedEOF: &reachedEOF)
            if !ok {
                return
            }
        }
    }

    private func decodeOneChunk(
        into decodeBuf: UnsafeMutablePointer<Float>,
        maxFrames: Int,
        generation: UInt64,
        reachedEOF: inout Bool
    ) -> Bool {
        var frameCount = UInt32(maxFrames)
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(maxFrames * 2 * MemoryLayout<Float>.size),
                mData: decodeBuf
            )
        )

        let status = ExtAudioFileRead(extAudioFile, &frameCount, &abl)
        if status != noErr {
            workerCondition.lock()
            let stopped = workerShouldStop
            workerCondition.unlock()
            if !stopped {
                let err = NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                    NSLocalizedDescriptionKey: "ExtAudioFileRead failed (\(status))"
                ])
                onDecodeError?(err)
            }
            return false
        }

        if frameCount == 0 {
            reachedEOF = true
            ringBuffer.markEOF(generation: generation)
            return true
        }

        var offsetFrames = 0
        let total = Int(frameCount)
        while offsetFrames < total {
            workerCondition.lock()
            let stopped = workerShouldStop
            let seekPending = pendingSeekSeconds != nil
            let currentGen = activeGeneration
            workerCondition.unlock()
            if stopped { return false }
            if seekPending || currentGen != generation { return true }

            let wrote = ringBuffer.write(
                from: decodeBuf.advanced(by: offsetFrames * 2),
                frameCount: total - offsetFrames,
                generation: generation
            )
            offsetFrames += wrote
            if offsetFrames < total {
                workerCondition.lock()
                workerCondition.wait(until: Date().addingTimeInterval(0.008))
                workerCondition.unlock()
            }
        }
        return true
    }

    private static func resolveSourceBitDepth(from asbd: AudioStreamBasicDescription, codec: String) -> Int {
        if asbd.mBitsPerChannel > 0 {
            return Int(asbd.mBitsPerChannel)
        }
        if asbd.mFormatID == kAudioFormatFLAC || asbd.mFormatID == kAudioFormatAppleLossless {
            switch asbd.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData:
                return 16
            case kAppleLosslessFormatFlag_20BitSourceData:
                return 20
            case kAppleLosslessFormatFlag_24BitSourceData:
                return 24
            case kAppleLosslessFormatFlag_32BitSourceData:
                return 32
            default:
                return 16
            }
        }
        return codec.lowercased().contains("flac") ? 16 : 16
    }
}

// MARK: - AudioFile C Callbacks

private final class AudioFileCallbackContext: @unchecked Sendable {
    let source: AudioByteDataSource
    init(source: AudioByteDataSource) {
        self.source = source
    }
}

private let halAudioFileReadProc: AudioFile_ReadProc = { clientData, position, requestCount, buffer, actualCount in
    let ctx = Unmanaged<AudioFileCallbackContext>.fromOpaque(clientData).takeUnretainedValue()
    let total = ctx.source.totalSize
    if total > 0 && position >= total {
        actualCount.pointee = 0
        return kAudioFileEndOfFileError
    }

    let (readBytes, status) = ctx.source.read(offset: position, length: Int(requestCount), into: buffer)
    actualCount.pointee = UInt32(max(0, readBytes))
    if status != noErr {
        return status
    }
    if readBytes == 0 && requestCount > 0 {
        return kAudioFileEndOfFileError
    }
    return noErr
}

private let halAudioFileGetSizeProc: AudioFile_GetSizeProc = { clientData in
    let ctx = Unmanaged<AudioFileCallbackContext>.fromOpaque(clientData).takeUnretainedValue()
    return ctx.source.totalSize
}

// MARK: - Real-Time AUHAL Render Context & Callback

private final class HALRenderContext: @unchecked Sendable {
    let ringBuffer: PCMStreamRingBuffer
    let sampleRate: Double
    let rampFrames: Int
    let bypassVolume: Bool

    var onEOFReached: (@Sendable () -> Void)?

    private struct Counters {
        var baseStartSeconds: Double
        var playedFrames: Int64 = 0
        var targetVolume: Float
        var currentVolume: Float
        var fadeInRemaining: Int
        var fadeOutTotal: Int = 0
        var fadeOutRemaining: Int = 0
        var isFadingOut: Bool = false
        var eofSignaled: Bool = false
    }

    private let lock: OSAllocatedUnfairLock<Counters>
    private let fadeOutDoneSemaphore = DispatchSemaphore(value: 0)

    init(
        ringBuffer: PCMStreamRingBuffer,
        sampleRate: Double,
        initialSeconds: Double,
        targetVolume: Float,
        bypassVolume: Bool
    ) {
        let safeRate = sampleRate > 0 ? sampleRate : 44_100.0
        let ramp = max(1, Int((0.005 * safeRate).rounded()))
        self.ringBuffer = ringBuffer
        self.sampleRate = safeRate
        self.rampFrames = ramp
        self.bypassVolume = bypassVolume
        let clampedVol = max(0.0, min(1.0, targetVolume))
        self.lock = OSAllocatedUnfairLock(
            initialState: Counters(
                baseStartSeconds: initialSeconds,
                targetVolume: clampedVol,
                currentVolume: clampedVol,
                fadeInRemaining: ramp
            )
        )
    }

    func setTargetVolume(_ volume: Float) {
        lock.withLock { state in
            state.targetVolume = volume
        }
    }

    func resetForSeek(startSeconds: Double, triggerFadeIn: Bool) {
        lock.withLock { state in
            state.baseStartSeconds = startSeconds
            state.playedFrames = 0
            state.eofSignaled = false
            state.isFadingOut = false
            state.fadeOutRemaining = 0
            if triggerFadeIn {
                state.fadeInRemaining = rampFrames
            }
        }
    }

    func currentPlaybackSeconds() -> Double {
        let (base, played) = lock.withLock { ($0.baseStartSeconds, $0.playedFrames) }
        return base + Double(played) / sampleRate
    }

    func triggerFadeOutAndWait(timeoutMs: Int) {
        lock.withLock { state in
            state.isFadingOut = true
            state.fadeOutTotal = rampFrames
            state.fadeOutRemaining = rampFrames
        }
        _ = fadeOutDoneSemaphore.wait(timeout: .now() + .milliseconds(max(1, timeoutMs)))
    }

    @inline(__always)
    func render(into ioData: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, let firstBuf = ioData.first, let mData = firstBuf.mData else {
            return
        }

        let outPtr = mData.assumingMemoryBound(to: Float.self)
        let (framesRead, reachedEOF) = ringBuffer.readRealtime(into: outPtr, frameCount: frameCount)

        let snap = lock.withLock { state -> (
            targetVol: Float,
            startVol: Float,
            fadeInRem: Int,
            fadingOut: Bool,
            fadeOutTotal: Int,
            fadeOutRem: Int,
            shouldSignalEOF: Bool,
            shouldSignalFadeDone: Bool
        ) in
            state.playedFrames += Int64(framesRead)
            let triggerEOF = reachedEOF && !state.eofSignaled
            if triggerEOF {
                state.eofSignaled = true
            }

            let curFadeIn = state.fadeInRemaining
            state.fadeInRemaining = max(0, curFadeIn - frameCount)

            let curFadingOut = state.isFadingOut
            let curFadeOutRem = state.fadeOutRemaining
            let curFadeOutTotal = state.fadeOutTotal
            var signalFadeDone = false
            if curFadingOut {
                let nextRem = max(0, curFadeOutRem - frameCount)
                state.fadeOutRemaining = nextRem
                if curFadeOutRem > 0 && nextRem == 0 {
                    signalFadeDone = true
                }
            }

            let targetVol = state.targetVolume
            let curVol = state.currentVolume
            if !bypassVolume {
                state.currentVolume = targetVol
            }

            return (
                targetVol,
                curVol,
                curFadeIn,
                curFadingOut,
                curFadeOutTotal,
                curFadeOutRem,
                triggerEOF,
                signalFadeDone
            )
        }

        // Fast-path bit-perfect passthrough: zero float multiplications when unity gain & no ramp active
        let needsVolumeScaling = !bypassVolume &&
            (abs(snap.startVol - 1.0) > 0.0001 || abs(snap.targetVol - 1.0) > 0.0001)
        let needsFadeIn = snap.fadeInRem > 0
        let needsFadeOut = snap.fadingOut

        if needsVolumeScaling || needsFadeIn || needsFadeOut {
            let totalSamples = frameCount * 2
            let invRamp = 1.0 / Float(max(1, rampFrames))
            let volStep = (snap.targetVol - snap.startVol) / Float(max(1, frameCount))
            let fadeOutDenom = Float(max(1, snap.fadeOutTotal))

            var frame = 0
            var sampleIdx = 0
            while sampleIdx < totalSamples {
                var gain: Float = bypassVolume ? 1.0 : (snap.startVol + volStep * Float(frame))

                if needsFadeIn && frame < snap.fadeInRem {
                    let completedInRamp = rampFrames - (snap.fadeInRem - frame)
                    let rampGain = max(0.0, min(1.0, Float(completedInRamp) * invRamp))
                    gain *= rampGain
                }

                if needsFadeOut {
                    let rem = snap.fadeOutRem - frame
                    let outGain = rem <= 0 ? Float(0.0) : max(0.0, min(1.0, Float(rem) / fadeOutDenom))
                    gain *= outGain
                }

                outPtr[sampleIdx] *= gain
                outPtr[sampleIdx + 1] *= gain

                frame += 1
                sampleIdx += 2
            }
        }

        if snap.shouldSignalFadeDone {
            fadeOutDoneSemaphore.signal()
        }

        if snap.shouldSignalEOF {
            onEOFReached?()
        }
    }
}

private let halRenderCallback: AURenderCallback = { inRefCon, ioActionFlags, _, _, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let ctx = Unmanaged<HALRenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    ctx.render(into: abl, frameCount: Int(inNumberFrames))
    return noErr
}
