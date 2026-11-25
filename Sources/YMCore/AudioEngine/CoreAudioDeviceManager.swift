import Foundation
import CoreAudio
import AudioToolbox
import Observation
import os

// MARK: - Models

public enum AudioTransportKind: String, Sendable, Equatable {
    case builtIn
    case usb
    case thunderbolt
    case hdmiDisplayPort
    case bluetooth
    case airPlay
    case virtualOrAggregate
    case other

    public var supportsExclusiveMode: Bool {
        switch self {
        case .builtIn, .usb, .thunderbolt, .hdmiDisplayPort, .other:
            return true
        case .bluetooth, .airPlay, .virtualOrAggregate:
            return false
        }
    }

    public var badgeLabel: String {
        switch self {
        case .builtIn: return "Встроенное"
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .hdmiDisplayPort: return "HDMI / DP"
        case .bluetooth: return "Bluetooth"
        case .airPlay: return "AirPlay"
        case .virtualOrAggregate: return "Виртуальное"
        case .other: return "Аудио"
        }
    }

    init(rawTransportType: UInt32) {
        switch rawTransportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            self = .hdmiDisplayPort
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            self = .airPlay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            self = .virtualOrAggregate
        default:
            self = .other
        }
    }
}

public struct AudioOutputDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: AudioTransportKind
    public let nominalSampleRate: Double
    public let supportedSampleRates: [Double]
    public let outputChannelCount: Int
    public let isDefaultOutput: Bool
}

public struct AcquiredDeviceSession: Sendable {
    public let deviceID: AudioDeviceID
    public let deviceUID: String
    public let deviceName: String
    public let transport: AudioTransportKind
    public let targetSampleRate: Double
    public let actualSampleRate: Double
    public let hogModeAcquired: Bool
    public let integerModeActive: Bool
    public let originalSampleRate: Double
    public let originalStreamID: AudioStreamID?
    public let originalPhysicalFormat: AudioStreamBasicDescription?
    public let warningMessage: String?
}

// MARK: - CoreAudio Device Manager

/// Manages CoreAudio HAL output devices, sample rate switching, exclusive Hog Mode,
/// integer physical stream format negotiation, hot-plug observation, and atexit cleanup.
@Observable
@MainActor
public final class CoreAudioDeviceManager {
    public static let shared = CoreAudioDeviceManager()

    public private(set) var outputDevices: [AudioOutputDeviceInfo] = []

    @ObservationIgnored public var onDevicesListChanged: (@MainActor () -> Void)?
    @ObservationIgnored public var onActiveDeviceDisconnected: (@MainActor (AudioDeviceID) -> Void)?
    @ObservationIgnored public var onDefaultOutputDeviceChanged: (@MainActor () -> Void)?

    // MARK: - Emergency Hog Cleanup State

    private struct EmergencyHogRecord: Sendable {
        let deviceID: AudioDeviceID
        let originalSampleRate: Double
        let streamID: AudioStreamID?
        let originalPhysicalFormat: AudioStreamBasicDescription?
        let hogModeAcquired: Bool
    }

    private nonisolated static let emergencyHogState = OSAllocatedUnfairLock<EmergencyHogRecord?>(initialState: nil)

    private nonisolated static let registerAtExitHandler: Void = {
        atexit {
            CoreAudioDeviceManager.emergencyReleaseHogModeSync()
        }
    }()

    /// Synchronously restores device format/rate and releases Hog Mode on abnormal exit or termination.
    public nonisolated static func emergencyReleaseHogModeSync() {
        guard let record = emergencyHogState.withLock({ state -> EmergencyHogRecord? in
            let current = state
            state = nil
            return current
        }) else {
            return
        }

        if Self.isDeviceAlive(record.deviceID) {
            if let streamID = record.streamID, var origFmt = record.originalPhysicalFormat {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyPhysicalFormat,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectSetPropertyData(
                    streamID,
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                    &origFmt
                )
            }

            if record.originalSampleRate > 0 {
                let currentRate = Self.readFloat64Property(
                    objectID: record.deviceID,
                    selector: kAudioDevicePropertyNominalSampleRate,
                    scope: kAudioObjectPropertyScopeGlobal
                ) ?? 0
                if abs(currentRate - record.originalSampleRate) >= 1.0 {
                    var rate = record.originalSampleRate
                    var addr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyNominalSampleRate,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectSetPropertyData(
                        record.deviceID,
                        &addr,
                        0,
                        nil,
                        UInt32(MemoryLayout<Float64>.size),
                        &rate
                    )
                }
            }

            if record.hogModeAcquired {
                let holder = Self.readPidProperty(
                    objectID: record.deviceID,
                    selector: kAudioDevicePropertyHogMode,
                    scope: kAudioObjectPropertyScopeGlobal
                )
                if holder == getpid() {
                    var releasePid: pid_t = -1
                    var addr = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyHogMode,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectSetPropertyData(
                        record.deviceID,
                        &addr,
                        0,
                        nil,
                        UInt32(MemoryLayout<pid_t>.size),
                        &releasePid
                    )
                }
            }
        }
    }

    // MARK: - Sample Rate Selection

    private nonisolated static let standardSampleRateGrid: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    /// Selects the highest-fidelity hardware sample rate matching `sourceRate`:
    /// 1) exact match -> 2) lowest integer upward multiple (2x, 4x, 8x) -> 3) lowest rate >= source -> 4) device maximum.
    public static func selectBestSampleRate(sourceRate: Double, supportedRates: [Double]) -> Double {
        let cleaned = supportedRates.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !cleaned.isEmpty else { return sourceRate }

        // 1. Exact match
        if let exact = cleaned.first(where: { abs($0 - sourceRate) < 1.0 }) {
            return exact
        }

        // 2. Integer multiples upward (2x, 4x, 8x)
        let multiples: [Double] = [2.0, 4.0, 8.0]
        if let multiple = cleaned.first(where: { rate in
            multiples.contains(where: { abs(rate - sourceRate * $0) < 1.0 })
        }) {
            return multiple
        }

        // 3. Nearest supported rate >= sourceRate
        if let higher = cleaned.first(where: { $0 >= sourceRate }) {
            return higher
        }

        // 4. Fallback to highest device rate
        return cleaned.last ?? sourceRate
    }

    // MARK: - System Listeners

    @ObservationIgnored private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var activeAliveDeviceID: AudioDeviceID?
    @ObservationIgnored private var activeAliveListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refreshDevices()
        installSystemPropertyListeners()
    }

    private func installSystemPropertyListeners() {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDevices()
                self.onDevicesListChanged?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(sysObj, &devicesAddr, DispatchQueue.main, devBlock) == noErr {
            devicesListenerBlock = devBlock
        }

        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshDevices()
                self.onDefaultOutputDeviceChanged?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(sysObj, &defaultAddr, DispatchQueue.main, defBlock) == noErr {
            defaultDeviceListenerBlock = defBlock
        }
    }

    public func watchActiveDevice(_ deviceID: AudioDeviceID) {
        unwatchActiveDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !Self.isDeviceAlive(deviceID) {
                    self.unwatchActiveDevice()
                    self.refreshDevices()
                    self.onActiveDeviceDisconnected?(deviceID)
                }
            }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block) == noErr {
            activeAliveDeviceID = deviceID
            activeAliveListenerBlock = block
        }
    }

    public func unwatchActiveDevice() {
        guard let devID = activeAliveDeviceID, let block = activeAliveListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(devID, &addr, DispatchQueue.main, block)
        activeAliveDeviceID = nil
        activeAliveListenerBlock = nil
    }

    // MARK: - Enumeration & Resolution

    public func refreshDevices() {
        let defaultID = Self.readDefaultOutputDeviceID()
        let allDeviceIDs = Self.readAllAudioDeviceIDs()

        var list: [AudioOutputDeviceInfo] = []
        list.reserveCapacity(allDeviceIDs.count)

        for deviceID in allDeviceIDs {
            let outputChannels = Self.readOutputChannelCount(deviceID: deviceID)
            guard outputChannels > 0 else { continue }

            let uid = Self.readCFStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "device-\(deviceID)"

            let name = Self.readCFStringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "Audio Device \(deviceID)"

            let rawTransport = Self.readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? 0
            let transport = AudioTransportKind(rawTransportType: rawTransport)

            let nominalRate = Self.readFloat64Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? 44_100.0

            let supportedRates = Self.readSupportedSampleRates(deviceID: deviceID, fallbackRate: nominalRate)

            list.append(
                AudioOutputDeviceInfo(
                    id: deviceID,
                    uid: uid,
                    name: name,
                    transport: transport,
                    nominalSampleRate: nominalRate,
                    supportedSampleRates: supportedRates,
                    outputChannelCount: outputChannels,
                    isDefaultOutput: (defaultID != nil && deviceID == defaultID)
                )
            )
        }

        // Keep default device visible cleanly near top, then sort alphabetically by name
        list.sort { lhs, rhs in
            if lhs.isDefaultOutput != rhs.isDefaultOutput {
                return lhs.isDefaultOutput
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        self.outputDevices = list
    }

    public func resolveDevice(preferredUID: String) -> AudioOutputDeviceInfo? {
        refreshDevices()
        if !preferredUID.isEmpty,
           let matched = outputDevices.first(where: { $0.uid == preferredUID }) {
            return matched
        }
        if let defaultID = Self.readDefaultOutputDeviceID(),
           let matchedDefault = outputDevices.first(where: { $0.id == defaultID }) {
            return matchedDefault
        }
        return outputDevices.first
    }

    // MARK: - Acquire & Release Session

    public func acquireDevice(
        preferredUID: String,
        sourceSampleRate: Double,
        sourceBitDepth: Int,
        switchSampleRate: Bool,
        requestHogMode: Bool
    ) async -> AcquiredDeviceSession? {
        guard let device = resolveDevice(preferredUID: preferredUID) else {
            return nil
        }

        let originalSampleRate = Self.readFloat64Property(
            objectID: device.id,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? device.nominalSampleRate

        // Step 2: Check transport support for exclusive capture / rate switching
        if !device.transport.supportsExclusiveMode {
            let warning: String?
            if requestHogMode || switchSampleRate {
                warning = "Устройство \(device.name) (\(device.transport.badgeLabel)) не поддерживает эксклюзивный захват — используется прямой вывод."
            } else {
                warning = nil
            }
            watchActiveDevice(device.id)
            return AcquiredDeviceSession(
                deviceID: device.id,
                deviceUID: device.uid,
                deviceName: device.name,
                transport: device.transport,
                targetSampleRate: device.nominalSampleRate,
                actualSampleRate: device.nominalSampleRate,
                hogModeAcquired: false,
                integerModeActive: false,
                originalSampleRate: originalSampleRate,
                originalStreamID: nil,
                originalPhysicalFormat: nil,
                warningMessage: warning
            )
        }

        _ = Self.registerAtExitHandler

        var warnings: [String] = []
        var hogAcquired = false

        // Step 3: Exclusive Hog Mode
        if requestHogMode {
            let myPid = getpid()
            let existingPid = Self.readPidProperty(
                objectID: device.id,
                selector: kAudioDevicePropertyHogMode,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? pid_t(-1)

            if existingPid != pid_t(-1) && existingPid != myPid {
                warnings.append("Эксклюзивный режим занят другим приложением (PID \(existingPid)). Используется общий доступ.")
            } else {
                var targetPid = myPid
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyHogMode,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let setStatus = AudioObjectSetPropertyData(
                    device.id,
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<pid_t>.size),
                    &targetPid
                )
                let verifiedPid = Self.readPidProperty(
                    objectID: device.id,
                    selector: kAudioDevicePropertyHogMode,
                    scope: kAudioObjectPropertyScopeGlobal
                ) ?? pid_t(-1)

                if setStatus == noErr && verifiedPid == myPid {
                    hogAcquired = true
                    Self.emergencyHogState.withLock {
                        $0 = EmergencyHogRecord(
                            deviceID: device.id,
                            originalSampleRate: originalSampleRate,
                            streamID: nil,
                            originalPhysicalFormat: nil,
                            hogModeAcquired: true
                        )
                    }
                } else if verifiedPid != pid_t(-1) && verifiedPid != myPid {
                    warnings.append("Эксклюзивный режим занят другим приложением (PID \(verifiedPid)). Используется общий доступ.")
                } else {
                    warnings.append("Не удалось активировать эксклюзивный режим (код \(setStatus)). Используется общий доступ.")
                }
            }
        }

        // Step 4: Sample Rate Switching
        let validSourceRate = (sourceSampleRate.isFinite && sourceSampleRate > 0) ? sourceSampleRate : originalSampleRate
        var targetRate = originalSampleRate
        var actualRate = originalSampleRate

        if switchSampleRate || hogAcquired {
            let bestRate = Self.selectBestSampleRate(
                sourceRate: validSourceRate,
                supportedRates: device.supportedSampleRates
            )
            targetRate = bestRate

            if abs(originalSampleRate - bestRate) >= 1.0 {
                var newRate = bestRate
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectSetPropertyData(
                    device.id,
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float64>.size),
                    &newRate
                )
                if status == noErr {
                    // Wait up to 1.5s for hardware clock lock (50 * 30 ms)
                    var settled = originalSampleRate
                    for _ in 0..<50 {
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        let current = Self.readFloat64Property(
                            objectID: device.id,
                            selector: kAudioDevicePropertyNominalSampleRate,
                            scope: kAudioObjectPropertyScopeGlobal
                        ) ?? settled
                        settled = current
                        if abs(current - bestRate) < 1.0 {
                            break
                        }
                    }
                    // Allow external USB DAC output relay to settle cleanly
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    actualRate = Self.readFloat64Property(
                        objectID: device.id,
                        selector: kAudioDevicePropertyNominalSampleRate,
                        scope: kAudioObjectPropertyScopeGlobal
                    ) ?? settled
                } else {
                    warnings.append("ЦАП отклонил переключение частоты на \(Int(bestRate)) Гц (код \(status)).")
                    actualRate = Self.readFloat64Property(
                        objectID: device.id,
                        selector: kAudioDevicePropertyNominalSampleRate,
                        scope: kAudioObjectPropertyScopeGlobal
                    ) ?? originalSampleRate
                }
            }
        }

        // Step 5: Integer Physical Stream Format (best-effort when Hog Mode is active)
        var integerModeActive = false
        var origStreamID: AudioStreamID?
        var origPhysicalFormat: AudioStreamBasicDescription?

        if hogAcquired, let firstOutputStreamID = Self.readOutputStreamIDs(deviceID: device.id).first {
            if let existingFmt = Self.readStreamPhysicalFormat(streamID: firstOutputStreamID) {
                origStreamID = firstOutputStreamID
                origPhysicalFormat = existingFmt

                if let candidate = Self.findBestIntegerPhysicalFormat(
                    streamID: firstOutputStreamID,
                    targetSampleRate: actualRate,
                    sourceBitDepth: sourceBitDepth
                ) {
                    var mutableCandidate = candidate
                    var addr = AudioObjectPropertyAddress(
                        mSelector: kAudioStreamPropertyPhysicalFormat,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    let fmtStatus = AudioObjectSetPropertyData(
                        firstOutputStreamID,
                        &addr,
                        0,
                        nil,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                        &mutableCandidate
                    )
                    if fmtStatus == noErr {
                        integerModeActive = true
                    }
                }
            }
        }

        // Keep emergency state up-to-date whenever we hold Hog Mode or modified sample rate / stream format
        if hogAcquired || abs(actualRate - originalSampleRate) >= 1.0 {
            let emergencyRecord = EmergencyHogRecord(
                deviceID: device.id,
                originalSampleRate: originalSampleRate,
                streamID: integerModeActive ? origStreamID : nil,
                originalPhysicalFormat: integerModeActive ? origPhysicalFormat : nil,
                hogModeAcquired: hogAcquired
            )
            Self.emergencyHogState.withLock {
                $0 = emergencyRecord
            }
        }

        watchActiveDevice(device.id)
        refreshDevices()

        let warningText = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return AcquiredDeviceSession(
            deviceID: device.id,
            deviceUID: device.uid,
            deviceName: device.name,
            transport: device.transport,
            targetSampleRate: targetRate,
            actualSampleRate: actualRate,
            hogModeAcquired: hogAcquired,
            integerModeActive: integerModeActive,
            originalSampleRate: originalSampleRate,
            originalStreamID: origStreamID,
            originalPhysicalFormat: origPhysicalFormat,
            warningMessage: warningText
        )
    }

    public func releaseDevice(_ session: AcquiredDeviceSession) {
        if activeAliveDeviceID == session.deviceID {
            unwatchActiveDevice()
        }

        Self.emergencyHogState.withLock { state in
            if state?.deviceID == session.deviceID {
                state = nil
            }
        }

        guard Self.isDeviceAlive(session.deviceID) else {
            refreshDevices()
            return
        }

        if session.integerModeActive,
           let streamID = session.originalStreamID,
           var origFmt = session.originalPhysicalFormat {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyPhysicalFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(
                streamID,
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &origFmt
            )
        }

        let currentRate = Self.readFloat64Property(
            objectID: session.deviceID,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? session.actualSampleRate

        if abs(currentRate - session.originalSampleRate) >= 1.0 && session.originalSampleRate > 0 {
            var restoreRate = session.originalSampleRate
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectSetPropertyData(
                session.deviceID,
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &restoreRate
            )
        }

        if session.hogModeAcquired {
            let currentHogPid = Self.readPidProperty(
                objectID: session.deviceID,
                selector: kAudioDevicePropertyHogMode,
                scope: kAudioObjectPropertyScopeGlobal
            )
            if currentHogPid == getpid() {
                var releasePid: pid_t = -1
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyHogMode,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectSetPropertyData(
                    session.deviceID,
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<pid_t>.size),
                    &releasePid
                )
            }
        }

        refreshDevices()
    }

    // MARK: - CoreAudio Property Helpers

    private nonisolated static func isDeviceAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        return (readUInt32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? 0) != 0
    }

    private nonisolated static func readDefaultOutputDeviceID() -> AudioDeviceID? {
        var devID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &devID
        )
        guard status == noErr, devID != kAudioObjectUnknown else { return nil }
        return devID
    }

    private nonisolated static func readAllAudioDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.filter { $0 != kAudioObjectUnknown }
    }

    private nonisolated static func readOutputChannelCount(deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, rawPtr) == noErr else {
            return 0
        }
        let ablPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private nonisolated static func readSupportedSampleRates(deviceID: AudioDeviceID, fallbackRate: Double) -> [Double] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioValueRange>.size) else {
            return [fallbackRate]
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ranges) == noErr else {
            return [fallbackRate]
        }

        var result: [Double] = []
        result.reserveCapacity(count * 2)

        let appendRate = { (candidate: Double) in
            guard candidate.isFinite && candidate > 0 else { return }
            if !result.contains(where: { abs($0 - candidate) < 1.0 }) {
                result.append(candidate)
            }
        }

        for range in ranges {
            if abs(range.mMaximum - range.mMinimum) < 0.5 {
                appendRate(range.mMinimum)
            } else {
                appendRate(range.mMinimum)
                for gridRate in standardSampleRateGrid {
                    if gridRate >= range.mMinimum - 0.5 && gridRate <= range.mMaximum + 0.5 {
                        appendRate(gridRate)
                    }
                }
                appendRate(range.mMaximum)
            }
        }

        if result.isEmpty {
            result.append(fallbackRate)
        }
        return result.sorted()
    }

    private nonisolated static func readOutputStreamIDs(deviceID: AudioDeviceID) -> [AudioStreamID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size) else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streamIDs = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &streamIDs) == noErr else {
            return []
        }
        return streamIDs
    }

    private nonisolated static func readStreamPhysicalFormat(streamID: AudioStreamID) -> AudioStreamBasicDescription? {
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &fmt) == noErr else {
            return nil
        }
        return fmt
    }

    private nonisolated static func findBestIntegerPhysicalFormat(
        streamID: AudioStreamID,
        targetSampleRate: Double,
        sourceBitDepth: Int
    ) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamRangedDescription>.size) else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var formats = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(
                mFormat: AudioStreamBasicDescription(),
                mSampleRateRange: AudioValueRange(mMinimum: 0, mMaximum: 0)
            ),
            count: count
        )
        guard AudioObjectGetPropertyData(streamID, &addr, 0, nil, &size, &formats) == noErr else {
            return nil
        }

        let minimumBits = max(16, sourceBitDepth)
        var bestFormat: AudioStreamBasicDescription?
        var bestScore = Int.min

        for ranged in formats {
            var fmt = ranged.mFormat
            let flags = fmt.mFormatFlags
            guard fmt.mFormatID == kAudioFormatLinearPCM,
                  (flags & kAudioFormatFlagIsNonMixable) != 0,
                  (flags & kAudioFormatFlagIsSignedInteger) != 0,
                  fmt.mChannelsPerFrame == 2 else {
                continue
            }

            let bits = Int(fmt.mBitsPerChannel)
            guard bits >= minimumBits else { continue }

            let rateCovered: Bool
            if ranged.mSampleRateRange.mMaximum > 0 {
                rateCovered = (targetSampleRate >= ranged.mSampleRateRange.mMinimum - 0.5) &&
                              (targetSampleRate <= ranged.mSampleRateRange.mMaximum + 0.5)
            } else {
                rateCovered = abs(fmt.mSampleRate - targetSampleRate) < 1.0 || fmt.mSampleRate == 0
            }
            guard rateCovered else { continue }

            // Prefer 24-bit or 32-bit integer PCM (with minimal excess above source bit depth)
            var score = 0
            if bits == 24 {
                score += 300
            } else if bits == 32 {
                score += 290
            } else {
                score += 100 + bits
            }
            if bits == minimumBits {
                score += 20
            }

            if score > bestScore {
                bestScore = score
                fmt.mSampleRate = targetSampleRate
                bestFormat = fmt
            }
        }

        return bestFormat
    }

    private nonisolated static func readCFStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var unmanagedStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &unmanagedStr) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanagedStr?.takeRetainedValue() else {
            return nil
        }
        return cfStr as String
    }

    private nonisolated static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private nonisolated static func readFloat64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Double? {
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Double(value)
    }

    private nonisolated static func readPidProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> pid_t? {
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
