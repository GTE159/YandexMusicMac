import Foundation
import os

/// Real-time safe Single-Producer Single-Consumer (SPSC) Float32 interleaved PCM ring buffer.
/// Uses `os.OSAllocatedUnfairLock` (macOS 13.0+) solely around index metadata updates —
/// zero allocations, zero ARC operations, and zero `memcpy` calls under the lock.
public final class PCMStreamRingBuffer: @unchecked Sendable {
    public let capacityFrames: Int
    public let channelCount: Int

    private let buffer: UnsafeMutablePointer<Float>
    private let floatStride = MemoryLayout<Float>.stride

    private struct State {
        var readFrame: Int64 = 0
        var writeFrame: Int64 = 0
        var isEOF: Bool = false
        var generation: UInt64 = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    public init(capacityFrames: Int = 131_072, channelCount: Int = 2) {
        let safeCap = max(1024, capacityFrames)
        let safeCh = max(1, channelCount)
        self.capacityFrames = safeCap
        self.channelCount = safeCh
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: safeCap * safeCh)
        self.buffer.initialize(repeating: 0.0, count: safeCap * safeCh)
    }

    deinit {
        buffer.deallocate()
    }

    public var availableFrames: Int {
        stateLock.withLock { state in
            max(0, Int(state.writeFrame - state.readFrame))
        }
    }

    public var freeFrames: Int {
        stateLock.withLock { state in
            max(0, capacityFrames - Int(state.writeFrame - state.readFrame))
        }
    }

    /// Writes up to `frameCount` interleaved Float32 frames from `src` on the decode thread.
    /// Rejects stale writes whose `generation` does not match the current buffer generation.
    @discardableResult
    public func write(from src: UnsafePointer<Float>, frameCount: Int, generation: UInt64) -> Int {
        guard frameCount > 0 else { return 0 }

        let snapshot = stateLock.withLock { state -> (valid: Bool, writeFrame: Int64, toWrite: Int) in
            guard state.generation == generation else {
                return (false, 0, 0)
            }
            let used = Int(state.writeFrame - state.readFrame)
            let free = max(0, capacityFrames - used)
            let count = min(frameCount, free)
            return (count > 0, state.writeFrame, count)
        }

        guard snapshot.valid, snapshot.toWrite > 0 else { return 0 }

        let writeIndex = Int(snapshot.writeFrame % Int64(capacityFrames))
        let firstFrames = min(snapshot.toWrite, capacityFrames - writeIndex)
        let secondFrames = snapshot.toWrite - firstFrames

        memcpy(
            buffer.advanced(by: writeIndex * channelCount),
            src,
            firstFrames * channelCount * floatStride
        )

        if secondFrames > 0 {
            memcpy(
                buffer,
                src.advanced(by: firstFrames * channelCount),
                secondFrames * channelCount * floatStride
            )
        }

        let committed = stateLock.withLock { state -> Int in
            guard state.generation == generation else { return 0 }
            state.writeFrame += Int64(snapshot.toWrite)
            return snapshot.toWrite
        }

        return committed
    }

    /// Reads `frameCount` interleaved Float32 frames directly inside the CoreAudio real-time IO proc.
    /// Any underrun tail is zero-filled (`memset`) outside the lock to prevent audio glitches.
    public func readRealtime(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> (framesRead: Int, reachedEOF: Bool) {
        guard frameCount > 0 else { return (0, false) }

        let snapshot = stateLock.withLock { state -> (readFrame: Int64, toRead: Int, gen: UInt64) in
            let available = max(0, Int(state.writeFrame - state.readFrame))
            let toRead = min(frameCount, available)
            return (state.readFrame, toRead, state.generation)
        }

        let toRead = snapshot.toRead
        if toRead > 0 {
            let readIndex = Int(snapshot.readFrame % Int64(capacityFrames))
            let firstFrames = min(toRead, capacityFrames - readIndex)
            let secondFrames = toRead - firstFrames

            memcpy(
                dst,
                buffer.advanced(by: readIndex * channelCount),
                firstFrames * channelCount * floatStride
            )

            if secondFrames > 0 {
                memcpy(
                    dst.advanced(by: firstFrames * channelCount),
                    buffer,
                    secondFrames * channelCount * floatStride
                )
            }
        }

        if toRead < frameCount {
            let remainingBytes = (frameCount - toRead) * channelCount * floatStride
            memset(dst.advanced(by: toRead * channelCount), 0, remainingBytes)
        }

        let result = stateLock.withLock { state -> (framesRead: Int, reachedEOF: Bool, invalidated: Bool) in
            guard state.generation == snapshot.gen else {
                return (0, false, true)
            }
            state.readFrame += Int64(toRead)
            let reachedEOF = state.isEOF && (state.readFrame >= state.writeFrame)
            return (toRead, reachedEOF, false)
        }

        if result.invalidated {
            memset(dst, 0, frameCount * channelCount * floatStride)
        }

        return (result.framesRead, result.reachedEOF)
    }

    public func markEOF(generation: UInt64) {
        stateLock.withLock { state in
            if state.generation == generation {
                state.isEOF = true
            }
        }
    }

    @discardableResult
    public func reset() -> UInt64 {
        stateLock.withLock { state in
            state.generation &+= 1
            state.readFrame = 0
            state.writeFrame = 0
            state.isEOF = false
            return state.generation
        }
    }
}
