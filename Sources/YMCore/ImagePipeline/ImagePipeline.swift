import Foundation
import AppKit

/// Thread-safe wrapper around Foundation's NSCache, which is internally thread-safe.
private final class ImageMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()

    init(maxCost: Int, countLimit: Int = 250) {
        cache.totalCostLimit = maxCost
        cache.countLimit = countLimit
    }

    func setMaxMemoryCost(mb: Int) {
        cache.totalCostLimit = max(5, mb) * 1024 * 1024
    }

    func object(forKey key: NSString) -> NSImage? {
        cache.object(forKey: key)
    }

    func setObject(_ obj: NSImage, forKey key: NSString, cost: Int) {
        cache.setObject(obj, forKey: key, cost: cost)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

/// MainActor-isolated image cache pipeline with configurable RAM cost limit (default 15 MB)
/// and off-main-thread hardware-accelerated downsampling via ImageIO (`CGImage` crosses
/// concurrency boundaries cleanly across macOS 14/15/27 SDKs without requiring `NSImage: Sendable`).
@MainActor
public final class ImagePipeline {
    public static let shared = ImagePipeline()

    private let memoryCache: ImageMemoryCache
    private var inFlightTasks: [String: Task<(CGImage, Int)?, Never>] = [:]

    public init(maxMemoryCost: Int = 15 * 1024 * 1024) {
        self.memoryCache = ImageMemoryCache(maxCost: maxMemoryCost)
    }

    /// Synchronous, thread-safe RAM cache lookup for zero-flicker fast path in SwiftUI views
    public nonisolated func cachedImage(for coverUri: String, size: YMCoverSize) -> NSImage? {
        guard !coverUri.isEmpty else { return nil }
        let keyString = "\(coverUri)_\(size.rawValue)"
        return memoryCache.object(forKey: keyString as NSString)
    }

    /// Dynamically adjusts the memory cache cost limit in megabytes
    public func setMaxMemoryCost(mb: Int) {
        memoryCache.setMaxMemoryCost(mb: mb)
    }

    /// Fetches image from cache or downloads and downsamples asynchronously off the main thread
    public func image(for coverUri: String?, size: YMCoverSize = .medium) async -> NSImage? {
        guard let coverUri = coverUri, !coverUri.isEmpty else { return nil }

        let keyString = "\(coverUri)_\(size.rawValue)"
        let cacheKey = keyString as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        if let existingTask = inFlightTasks[keyString] {
            if let (cgImage, _) = await existingTask.value {
                if let cached = memoryCache.object(forKey: cacheKey) {
                    return cached
                }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return image
            }
            return nil
        }

        let maxPixelSize: CGFloat
        switch size {
        case .small: maxPixelSize = 100
        case .medium: maxPixelSize = 200
        case .artwork: maxPixelSize = 300
        case .large: maxPixelSize = 400
        }

        let task = Task.detached(priority: .userInitiated) { () -> (CGImage, Int)? in
            if let offlineData = await OfflineStorageStore.shared.localCoverData(for: coverUri),
               !Task.isCancelled,
               let localResult = ImageDownsampler.downsampleCGImageWithCost(data: offlineData, maxPixelSize: maxPixelSize) {
                return localResult
            }
            guard !Task.isCancelled, let url = YMCoverURLBuilder.buildURL(from: coverUri, size: size) else {
                return nil
            }
            guard let result = await ImageDownsampler.fetchAndDownsampleCGImageWithCost(from: url, maxPixelSize: maxPixelSize),
                  !Task.isCancelled else {
                return nil
            }
            return result
        }

        inFlightTasks[keyString] = task
        let decoded = await task.value
        inFlightTasks.removeValue(forKey: keyString)

        guard let (cgImage, byteCost) = decoded else {
            return nil
        }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        memoryCache.setObject(image, forKey: cacheKey, cost: byteCost)
        return image
    }

    public func clearCache() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        memoryCache.removeAllObjects()
    }

    public func clearMemoryCache() {
        clearCache()
    }
}
