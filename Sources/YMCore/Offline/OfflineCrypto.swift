import Foundation
import CryptoKit
import IOKit

public enum OfflineCryptoError: Error, LocalizedError, Sendable {
    case invalidHeader
    case corruptedChunk(Int)
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid offline container header."
        case .corruptedChunk(let idx):
            return "Corrupted offline audio chunk #\(idx)."
        case .ioFailure(let msg):
            return "Offline I/O failure: \(msg)"
        }
    }
}

/// Binary header specification ("YMO1") for chunked AES-256-GCM offline audio containers.
public struct OfflineContainerHeader: Sendable, Equatable {
    public static let magic: [UInt8] = [0x59, 0x4D, 0x4F, 0x31] // "YMO1"
    public static let version: UInt8 = 1
    public static let headerByteSize: UInt64 = 32
    public static let defaultChunkSize: UInt32 = 65_536
    public static let gcmOverhead: UInt64 = 28 // 12-byte nonce + 16-byte tag

    public let chunkSize: UInt32
    public let plaintextSize: UInt64

    public init(chunkSize: UInt32, plaintextSize: UInt64) {
        self.chunkSize = chunkSize
        self.plaintextSize = plaintextSize
    }

    public var encodedChunkStride: UInt64 {
        UInt64(chunkSize) + Self.gcmOverhead
    }

    public func serialize() -> Data {
        var data = Data(capacity: Int(Self.headerByteSize))
        data.append(contentsOf: Self.magic)
        data.append(Self.version)
        data.append(contentsOf: [0, 0, 0]) // reserved padding (bytes 5..7)
        withUnsafeBytes(of: chunkSize.littleEndian) { data.append(contentsOf: $0) } // bytes 8..11
        withUnsafeBytes(of: plaintextSize.littleEndian) { data.append(contentsOf: $0) } // bytes 12..19
        data.append(contentsOf: repeatElement(UInt8(0), count: 12)) // bytes 20..31
        return data
    }

    public static func parse(from data: Data) throws -> OfflineContainerHeader {
        guard data.count >= Int(Self.headerByteSize) else {
            throw OfflineCryptoError.invalidHeader
        }
        guard Array(data.prefix(4)) == Self.magic, data[4] == Self.version else {
            throw OfflineCryptoError.invalidHeader
        }
        let chunkSize = data.subdata(in: 8..<12).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let plaintextSize = data.subdata(in: 12..<20).withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
        guard chunkSize >= 4096 && chunkSize <= 1_048_576 else {
            throw OfflineCryptoError.invalidHeader
        }
        return OfflineContainerHeader(chunkSize: chunkSize, plaintextSize: plaintextSize)
    }
}

/// Hardware-bound HKDF-SHA256 key derivation and streaming chunked AES-256-GCM encryption/decryption.
public enum OfflineCrypto: Sendable {
    public static let audioKey: SymmetricKey = deriveOfflineKey(namespace: "audio")
    public static let metaKey: SymmetricKey = deriveOfflineKey(namespace: "meta")

    public static func deriveOfflineKey(namespace: String = "audio") -> SymmetricKey {
        let machineUUID = hardwarePlatformUUID()
        let uid = getuid()
        let home = NSHomeDirectory()
        let material = "\(machineUUID)|uid:\(uid)|home:\(home)"
        let inputKey = SymmetricKey(data: Data(material.utf8))
        let salt = Data("com.yandexmusic.mac.offline.v1|\(namespace)".utf8)
        let info = Data("AES-256-GCM-Offline-\(namespace)".utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    public static func chunkAAD(trackId: String, chunkIndex: UInt64) -> Data {
        Data("\(trackId)|\(chunkIndex)".utf8)
    }

    public static func readHeader(from handle: FileHandle) throws -> OfflineContainerHeader {
        try handle.seek(toOffset: 0)
        guard let data = try handle.read(upToCount: Int(OfflineContainerHeader.headerByteSize)) else {
            throw OfflineCryptoError.invalidHeader
        }
        return try OfflineContainerHeader.parse(from: data)
    }

    public static func encryptFileStreaming(
        sourceURL: URL,
        destinationURL: URL,
        trackId: String,
        key: SymmetricKey,
        chunkSize: UInt32 = OfflineContainerHeader.defaultChunkSize
    ) throws -> OfflineContainerHeader {
        guard chunkSize >= 4096 && chunkSize <= 1_048_576 else {
            throw OfflineCryptoError.invalidHeader
        }

        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: sourceURL.path)
        let plaintextSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let header = OfflineContainerHeader(chunkSize: chunkSize, plaintextSize: plaintextSize)

        let parentDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: parentDir.path)
        }

        let tempURL = destinationURL.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tempURL.path) {
            try? fm.removeItem(at: tempURL)
        }

        var cleanupTemp = true
        defer {
            if cleanupTemp {
                try? fm.removeItem(at: tempURL)
            }
        }

        guard fm.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw OfflineCryptoError.ioFailure("Failed to create temporary encrypted file.")
        }

        let inHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? inHandle.close() }

        let outHandle = try FileHandle(forWritingTo: tempURL)
        defer { try? outHandle.close() }

        try outHandle.write(contentsOf: header.serialize())

        let targetChunkBytes = Int(chunkSize)
        var chunkIndex: UInt64 = 0
        var totalWrittenPlain: UInt64 = 0

        if plaintextSize > 0 {
            while true {
                let reachedEOF: Bool = try autoreleasepool {
                    var chunk = Data()
                    while chunk.count < targetChunkBytes {
                        let remaining = targetChunkBytes - chunk.count
                        guard let slice = try inHandle.read(upToCount: remaining), !slice.isEmpty else {
                            break
                        }
                        chunk.append(slice)
                    }

                    guard !chunk.isEmpty else {
                        return true
                    }

                    let aad = chunkAAD(trackId: trackId, chunkIndex: chunkIndex)
                    let sealedBox = try AES.GCM.seal(chunk, using: key, authenticating: aad)
                    guard let combined = sealedBox.combined else {
                        throw OfflineCryptoError.ioFailure("Failed to obtain AES-GCM combined output.")
                    }
                    try outHandle.write(contentsOf: combined)
                    totalWrittenPlain += UInt64(chunk.count)
                    chunkIndex += 1
                    return chunk.count < targetChunkBytes
                }

                if reachedEOF {
                    break
                }
            }
        }

        guard totalWrittenPlain == plaintextSize else {
            throw OfflineCryptoError.ioFailure("Source file size mismatch during encryption.")
        }

        try outHandle.synchronize()
        try outHandle.close()
        try inHandle.close()

        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destinationURL)
        }
        cleanupTemp = false

        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: destinationURL.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = destinationURL
        try? mutableURL.setResourceValues(resourceValues)

        return header
    }

    public static func decryptRange(
        from handle: FileHandle,
        header: OfflineContainerHeader,
        trackId: String,
        key: SymmetricKey,
        offset: UInt64,
        length: Int,
        onChunk: (Data) -> Bool
    ) throws {
        guard length > 0, offset < header.plaintextSize else { return }

        let (sum, overflow) = offset.addingReportingOverflow(UInt64(length))
        let reqEnd = overflow ? header.plaintextSize : min(sum, header.plaintextSize)
        guard offset < reqEnd else { return }

        let chunkSizeU64 = UInt64(header.chunkSize)
        let firstChunk = offset / chunkSizeU64
        let lastChunk = (reqEnd - 1) / chunkSizeU64

        for chunkIndex in firstChunk...lastChunk {
            let shouldContinue: Bool = try autoreleasepool {
                let plainStart = chunkIndex * chunkSizeU64
                let plainLen = min(chunkSizeU64, header.plaintextSize - plainStart)
                let encOffset = OfflineContainerHeader.headerByteSize + chunkIndex * header.encodedChunkStride
                let encLen = Int(plainLen + OfflineContainerHeader.gcmOverhead)

                try handle.seek(toOffset: encOffset)
                guard let encData = try handle.read(upToCount: encLen), encData.count == encLen else {
                    throw OfflineCryptoError.corruptedChunk(Int(chunkIndex))
                }

                let plaintext: Data
                do {
                    let sealedBox = try AES.GCM.SealedBox(combined: encData)
                    plaintext = try AES.GCM.open(
                        sealedBox,
                        using: key,
                        authenticating: chunkAAD(trackId: trackId, chunkIndex: chunkIndex)
                    )
                } catch {
                    throw OfflineCryptoError.corruptedChunk(Int(chunkIndex))
                }

                guard UInt64(plaintext.count) == plainLen else {
                    throw OfflineCryptoError.corruptedChunk(Int(chunkIndex))
                }

                let sliceStart = Int(max(offset, plainStart) - plainStart)
                let sliceEnd = Int(min(reqEnd, plainStart + plainLen) - plainStart)
                let slice = (sliceStart == 0 && sliceEnd == plaintext.count)
                    ? plaintext
                    : plaintext.subdata(in: sliceStart..<sliceEnd)
                return onChunk(slice)
            }

            if !shouldContinue {
                break
            }
        }
    }

    public static func sealSmallData(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw OfflineCryptoError.ioFailure("Failed to serialize sealed data.")
        }
        return combined
    }

    public static func openSmallData(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private static func hardwarePlatformUUID() -> String {
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard platformExpert != 0 else { return "fallback-mac-host" }
        defer { IOObjectRelease(platformExpert) }

        if let cfValue = IORegistryEntryCreateCFProperty(
            platformExpert,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String, !cfValue.isEmpty {
            return cfValue
        }
        return "fallback-mac-host"
    }
}
