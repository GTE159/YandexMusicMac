import Testing
import Foundation
import CryptoKit
import AudioToolbox
@testable import YMCore

@Suite("CoreAudio HAL Device Selection, Ring Buffer, Data Sources & Settings Tests")
struct CoreAudioHALTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YMCoreAudioHALTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    @Test("CoreAudioDeviceManager.selectBestSampleRate prioritizes exact match, integer multiples, nearest higher, then max")
    func testSelectBestSampleRate() {
        #expect(
            CoreAudioDeviceManager.selectBestSampleRate(
                sourceRate: 96_000,
                supportedRates: [44_100, 48_000, 96_000, 192_000]
            ) == 96_000
        )

        // Must pick 2x integer multiple 88.2 kHz instead of nearest >= 96 kHz
        #expect(
            CoreAudioDeviceManager.selectBestSampleRate(
                sourceRate: 44_100,
                supportedRates: [88_200, 96_000, 176_400]
            ) == 88_200
        )

        #expect(
            CoreAudioDeviceManager.selectBestSampleRate(
                sourceRate: 48_000,
                supportedRates: [44_100, 96_000, 192_000]
            ) == 96_000
        )

        // Fallback to nearest supported rate above source
        #expect(
            CoreAudioDeviceManager.selectBestSampleRate(
                sourceRate: 88_200,
                supportedRates: [44_100, 48_000, 96_000]
            ) == 96_000
        )

        // Fallback to device maximum when source exceeds all device rates
        #expect(
            CoreAudioDeviceManager.selectBestSampleRate(
                sourceRate: 192_000,
                supportedRates: [44_100, 48_000, 96_000]
            ) == 96_000
        )
    }

    @Test("PCMStreamRingBuffer wrap-around bit-exactness, underrun silence, EOF, and generation fencing")
    func testPCMStreamRingBufferBehavior() {
        let capFrames = 1024
        let ch = 2
        let rb = PCMStreamRingBuffer(capacityFrames: capFrames, channelCount: ch)
        let gen0: UInt64 = 0

        // Multi-cycle wrap-around write/read verifying exact bit pattern
        let stepFrames = 384
        var srcSamples = [Float](repeating: 0, count: stepFrames * ch)
        var dstSamples = [Float](repeating: -999, count: stepFrames * ch)
        var globalFrameIndex = 0

        for cycle in 0..<8 {
            for f in 0..<stepFrames {
                let valL = Float(globalFrameIndex + f) * 0.00125
                let valR = -valL
                srcSamples[f * 2] = valL
                srcSamples[f * 2 + 1] = valR
            }
            let wrote = srcSamples.withUnsafeBufferPointer { ptr in
                rb.write(from: ptr.baseAddress!, frameCount: stepFrames, generation: gen0)
            }
            #expect(wrote == stepFrames, "Cycle \(cycle) should write full chunk")

            let readRes = dstSamples.withUnsafeMutableBufferPointer { ptr in
                rb.readRealtime(into: ptr.baseAddress!, frameCount: stepFrames)
            }
            #expect(readRes.framesRead == stepFrames)
            #expect(readRes.reachedEOF == false)

            for i in 0..<(stepFrames * ch) {
                #expect(dstSamples[i] == srcSamples[i])
            }
            globalFrameIndex += stepFrames
        }

        // Write partial frames, mark EOF, and verify underrun tail is zero-filled and EOF flips true
        let tailFrames = 120
        var partialSrc = [Float](repeating: 0, count: tailFrames * ch)
        for i in 0..<(tailFrames * ch) {
            partialSrc[i] = Float(i + 1) * 0.5
        }
        let partialWrote = partialSrc.withUnsafeBufferPointer {
            rb.write(from: $0.baseAddress!, frameCount: tailFrames, generation: gen0)
        }
        #expect(partialWrote == tailFrames)
        rb.markEOF(generation: gen0)

        let overReadFrames = 256
        var overDst = [Float](repeating: 42.0, count: overReadFrames * ch)
        let eofRead = overDst.withUnsafeMutableBufferPointer {
            rb.readRealtime(into: $0.baseAddress!, frameCount: overReadFrames)
        }
        #expect(eofRead.framesRead == tailFrames)
        #expect(eofRead.reachedEOF == true)
        for i in 0..<(tailFrames * ch) {
            #expect(overDst[i] == partialSrc[i])
        }
        for i in (tailFrames * ch)..<(overReadFrames * ch) {
            #expect(overDst[i] == 0.0)
        }

        // reset() increments generation and rejects stale writes
        let gen1 = rb.reset()
        #expect(gen1 == gen0 + 1)
        #expect(rb.availableFrames == 0)

        let staleWrote = partialSrc.withUnsafeBufferPointer {
            rb.write(from: $0.baseAddress!, frameCount: tailFrames, generation: gen0)
        }
        #expect(staleWrote == 0)
        #expect(rb.availableFrames == 0)

        let freshWrote = partialSrc.withUnsafeBufferPointer {
            rb.write(from: $0.baseAddress!, frameCount: tailFrames, generation: gen1)
        }
        #expect(freshWrote == tailFrames)
    }

    @Test("OfflineEncryptedAudioDataSource decrypts arbitrary offsets across 64 KB chunks and returns clean EOF")
    func testOfflineEncryptedAudioDataSourceRoundTrip() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = SymmetricKey(size: .bits256)
        let trackId = "55443322"

        let totalBytes = 65_536 * 2 + 19_321
        var raw = [UInt8](repeating: 0, count: totalBytes)
        for i in 0..<totalBytes {
            raw[i] = UInt8((i * 17 + (i >> 7)) & 0xFF)
        }
        let expectedData = Data(raw)
        let srcURL = tempDir.appendingPathComponent("src.flac")
        let encURL = tempDir.appendingPathComponent("55443322.ymo")
        try expectedData.write(to: srcURL)

        _ = try OfflineCrypto.encryptFileStreaming(
            sourceURL: srcURL,
            destinationURL: encURL,
            trackId: trackId,
            key: key
        )

        let source = try OfflineEncryptedAudioDataSource(
            fileURL: encURL,
            trackId: "\(trackId):999",
            codec: "flac",
            key: key
        )
        defer { source.close() }

        #expect(source.totalSize == Int64(totalBytes))
        #expect(source.fileTypeHint == kAudioFileFLACType)
        #expect(OfflineEncryptedAudioDataSource.audioFileTypeHint(forCodec: "flac-mp4") == kAudioFileM4AType)

        // Read spanning boundary between chunk 0 (65536) and chunk 1 + chunk 2
        let readRanges: [(offset: Int64, length: Int)] = [
            (0, 512),
            (65_000, 2_048),
            (65_536 * 2 - 500, 4_000),
            (Int64(totalBytes - 200), 1_000)
        ]

        for r in readRanges {
            var outBuf = [UInt8](repeating: 0, count: r.length)
            let result = outBuf.withUnsafeMutableBytes { rawPtr in
                source.read(offset: r.offset, length: r.length, into: rawPtr.baseAddress!)
            }
            let expectedSliceEnd = min(totalBytes, Int(r.offset) + r.length)
            let expectedSliceLen = expectedSliceEnd - Int(r.offset)
            #expect(result.status == noErr)
            #expect(result.bytesRead == expectedSliceLen)
            #expect(Data(outBuf.prefix(result.bytesRead)) == expectedData.subdata(in: Int(r.offset)..<expectedSliceEnd))
        }

        // Past-EOF read returns (0, noErr)
        var eofBuf = [UInt8](repeating: 0, count: 64)
        let eofResult = eofBuf.withUnsafeMutableBytes {
            source.read(offset: Int64(totalBytes), length: 64, into: $0.baseAddress!)
        }
        #expect(eofResult.status == noErr)
        #expect(eofResult.bytesRead == 0)
    }

    @MainActor
    @Test("AudioQualitySettings persists CoreAudio HAL preferences and computes usesDirectHALBackend")
    func testAudioQualitySettingsHALPersistence() {
        let settings = AudioQualitySettings.shared
        let prevUID = settings.audioOutputDeviceUID
        let prevAutoRate = settings.autoSampleRateSwitching
        let prevHog = settings.exclusiveHogMode
        let prevFixedVol = settings.bitPerfectFixedVolume

        defer {
            settings.setAudioOutputDeviceUID(prevUID)
            settings.setAutoSampleRateSwitching(prevAutoRate)
            settings.setExclusiveHogMode(prevHog)
            settings.setBitPerfectFixedVolume(prevFixedVol)
        }

        settings.setAudioOutputDeviceUID("")
        settings.setAutoSampleRateSwitching(false)
        settings.setExclusiveHogMode(false)
        settings.setBitPerfectFixedVolume(true)

        #expect(settings.usesDirectHALBackend == false)
        #expect(UserDefaults.standard.string(forKey: "ym_audio_output_device_uid") == "")
        #expect(UserDefaults.standard.bool(forKey: "ym_audio_auto_sample_rate") == false)
        #expect(UserDefaults.standard.bool(forKey: "ym_audio_exclusive_hog_mode") == false)
        #expect(UserDefaults.standard.bool(forKey: "ym_audio_bit_perfect_fixed_volume") == true)

        settings.setExclusiveHogMode(true)
        #expect(settings.usesDirectHALBackend == true)

        settings.setExclusiveHogMode(false)
        settings.setAutoSampleRateSwitching(true)
        #expect(settings.usesDirectHALBackend == true)

        settings.setAutoSampleRateSwitching(false)
        settings.setAudioOutputDeviceUID("USB-DAC-TEST-UID")
        settings.setBitPerfectFixedVolume(false)
        #expect(settings.usesDirectHALBackend == true)
        #expect(UserDefaults.standard.string(forKey: "ym_audio_output_device_uid") == "USB-DAC-TEST-UID")
        #expect(UserDefaults.standard.bool(forKey: "ym_audio_bit_perfect_fixed_volume") == false)

        // Freshly initialized settings instance reads back persisted UserDefaults values
        let reloaded = AudioQualitySettings()
        #expect(reloaded.audioOutputDeviceUID == "USB-DAC-TEST-UID")
        #expect(reloaded.autoSampleRateSwitching == false)
        #expect(reloaded.exclusiveHogMode == false)
        #expect(reloaded.bitPerfectFixedVolume == false)
        #expect(reloaded.usesDirectHALBackend == true)
    }
}
