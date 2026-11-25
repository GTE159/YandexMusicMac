import Foundation
@preconcurrency import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

/// `AVAssetResourceLoaderDelegate` serving byte ranges directly from encrypted `YMO1` containers
/// via custom URL scheme `ymoffline://`, keeping memory usage bounded to ~128 KB.
public final class OfflineAssetResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "ymoffline"

    private let fileURL: URL
    private let trackId: String
    private let contentTypeUTI: String
    private let key: SymmetricKey
    private let queue: DispatchQueue

    // Accessed strictly inside `queue` (except `deinit`)
    private var fileHandle: FileHandle?
    private var header: OfflineContainerHeader?
    private var isInvalidated: Bool = false

    public init(fileURL: URL, trackId: String, codec: String, key: SymmetricKey) {
        self.fileURL = fileURL
        self.trackId = trackId
        self.contentTypeUTI = Self.uti(forCodec: codec)
        self.key = key
        self.queue = DispatchQueue(label: "com.flow.offline.loader.\(trackId)", qos: .userInitiated)
        super.init()
    }

    deinit {
        try? fileHandle?.close()
    }

    public func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isInvalidated = true
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    public static func makeAsset(
        fileURL: URL,
        trackId: String,
        codec: String,
        key: SymmetricKey
    ) -> (asset: AVURLAsset, delegate: OfflineAssetResourceLoaderDelegate)? {
        let ext = fileExtension(forCodec: codec)
        let encodedId = trackId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackId
        guard let url = URL(string: "\(scheme)://track/\(encodedId).\(ext)") else { return nil }
        let delegate = OfflineAssetResourceLoaderDelegate(
            fileURL: fileURL,
            trackId: trackId,
            codec: codec,
            key: key
        )
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)
        return (asset, delegate)
    }

    public static func uti(forCodec codec: String) -> String {
        let c = codec.lowercased()
        if c == "flac" {
            return UTType(filenameExtension: "flac")?.identifier ?? "org.xiph.flac"
        } else if c.contains("mp4") || c.contains("m4a") {
            return UTType.mpeg4Audio.identifier
        } else if c.contains("aac") {
            return UTType(filenameExtension: "aac")?.identifier ?? "public.aac-audio"
        }
        return UTType.mp3.identifier
    }

    public static func fileExtension(forCodec codec: String) -> String {
        let c = codec.lowercased()
        if c == "flac" { return "flac" }
        if c.contains("mp4") || c.contains("m4a") { return "m4a" }
        if c.contains("aac") { return "aac" }
        return "mp3"
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if isInvalidated {
            loadingRequest.finishLoading(with: CancellationError())
            return false
        }

        if loadingRequest.isCancelled {
            loadingRequest.finishLoading(with: CancellationError())
            return false
        }

        do {
            let handle: FileHandle
            let containerHeader: OfflineContainerHeader
            if let existingHandle = self.fileHandle, let existingHeader = self.header {
                handle = existingHandle
                containerHeader = existingHeader
            } else {
                let opened = try FileHandle(forReadingFrom: fileURL)
                let parsed = try OfflineCrypto.readHeader(from: opened)
                self.fileHandle = opened
                self.header = parsed
                handle = opened
                containerHeader = parsed
            }

            if let contentInfo = loadingRequest.contentInformationRequest {
                contentInfo.contentType = contentTypeUTI
                contentInfo.contentLength = Int64(containerHeader.plaintextSize)
                contentInfo.isByteRangeAccessSupported = true
            }

            guard let dataRequest = loadingRequest.dataRequest else {
                if !loadingRequest.isCancelled && !isInvalidated {
                    loadingRequest.finishLoading()
                }
                return true
            }

            let startOffset = UInt64(max(0, dataRequest.currentOffset))
            if startOffset >= containerHeader.plaintextSize {
                if !loadingRequest.isCancelled {
                    loadingRequest.finishLoading()
                }
                return true
            }

            let requestedLength: Int
            if dataRequest.requestsAllDataToEndOfResource {
                let remaining = containerHeader.plaintextSize - startOffset
                requestedLength = Int(min(remaining, UInt64(Int.max)))
            } else {
                requestedLength = dataRequest.requestedLength
            }

            guard requestedLength > 0 else {
                if !loadingRequest.isCancelled {
                    loadingRequest.finishLoading()
                }
                return true
            }

            try OfflineCrypto.decryptRange(
                from: handle,
                header: containerHeader,
                trackId: trackId,
                key: key,
                offset: startOffset,
                length: requestedLength
            ) { slice in
                if loadingRequest.isCancelled || self.isInvalidated {
                    return false
                }
                dataRequest.respond(with: slice)
                return !loadingRequest.isCancelled && !self.isInvalidated
            }

            if isInvalidated && !loadingRequest.isCancelled {
                loadingRequest.finishLoading(with: CancellationError())
            } else if !loadingRequest.isCancelled {
                loadingRequest.finishLoading()
            }
            return true
        } catch {
            if !loadingRequest.isCancelled {
                loadingRequest.finishLoading(with: error)
            }
            return true
        }
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // The active decryptRange closure exits early upon checking loadingRequest.isCancelled.
    }
}
