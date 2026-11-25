import Foundation
import Observation

/// Persistent configuration service for audio stream quality and codec preferences.
@Observable
@MainActor
public final class AudioQualitySettings {
    public static let shared = AudioQualitySettings()

    private let presetKey = "ym_audio_quality_preset"
    private let codecKey = "ym_audio_codec_pref"
    private let preloadFavoritesKey = "ym_preload_favorites_bg"
    private let imageCacheLimitKey = "ym_image_cache_limit_mb"
    private let crossfadeDurationKey = "ym_audio_crossfade_seconds"
    private let offlinePresetKey = "ym_offline_quality_preset"
    private let offlineCacheLimitKey = "ym_offline_cache_limit_gb"

    public var preset: YMAudioQualityPreset {
        didSet {
            UserDefaults.standard.set(preset.rawValue, forKey: presetKey)
        }
    }

    public var codecPreference: YMAudioCodecPreference {
        didSet {
            UserDefaults.standard.set(codecPreference.rawValue, forKey: codecKey)
        }
    }

    /// Background preload mode for entire Favorites library (default false for 45-65 MB memory limit)
    public var preloadAllFavoritesInBackground: Bool {
        didSet {
            UserDefaults.standard.set(preloadAllFavoritesInBackground, forKey: preloadFavoritesKey)
            if preloadAllFavoritesInBackground {
                LikesService.shared.startBackgroundCatalogPreload()
            } else {
                LikesService.shared.stopBackgroundCatalogPreloadAndPrune()
            }
        }
    }

    /// Maximum memory limit for cover images in megabytes (10, 15, 20, 50; default 15 MB)
    public var imageCacheLimitMB: Int {
        didSet {
            UserDefaults.standard.set(imageCacheLimitMB, forKey: imageCacheLimitKey)
            ImagePipeline.shared.setMaxMemoryCost(mb: imageCacheLimitMB)
        }
    }

    /// Smooth crossfade duration between consecutive tracks in seconds (0.0...12.0; 0.0 = disabled)
    public var crossfadeDuration: Double {
        didSet {
            let clamped = max(0.0, min(12.0, crossfadeDuration))
            if crossfadeDuration != clamped {
                crossfadeDuration = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: crossfadeDurationKey)
        }
    }

    /// Preferred audio quality preset when downloading tracks for offline playback (default `.high320`)
    public var offlineQualityPreset: YMAudioQualityPreset {
        didSet {
            UserDefaults.standard.set(offlineQualityPreset.rawValue, forKey: offlinePresetKey)
        }
    }

    /// Maximum disk quota for offline downloaded tracks in GB (`0` = unlimited, default `5`)
    public var offlineCacheLimitGB: Int {
        didSet {
            let allowed: Set<Int> = [0, 2, 5, 10, 20]
            let resolved = allowed.contains(offlineCacheLimitGB) ? offlineCacheLimitGB : 5
            if offlineCacheLimitGB != resolved {
                offlineCacheLimitGB = resolved
                return
            }
            UserDefaults.standard.set(resolved, forKey: offlineCacheLimitKey)
        }
    }

    public init() {
        let savedPresetStr = UserDefaults.standard.string(forKey: presetKey)
        let resolvedPreset = savedPresetStr.flatMap(YMAudioQualityPreset.init(rawValue:)) ?? .high320

        let savedCodecStr = UserDefaults.standard.string(forKey: codecKey)
        let resolvedCodec = savedCodecStr.flatMap(YMAudioCodecPreference.init(rawValue:)) ?? .any

        let savedPreload = UserDefaults.standard.bool(forKey: preloadFavoritesKey)
        let savedImageLimit = UserDefaults.standard.integer(forKey: imageCacheLimitKey)
        let resolvedImageLimit = savedImageLimit > 0 ? savedImageLimit : 15

        let savedCrossfade = UserDefaults.standard.double(forKey: crossfadeDurationKey)
        let resolvedCrossfade = max(0.0, min(12.0, savedCrossfade))

        let savedOfflinePresetStr = UserDefaults.standard.string(forKey: offlinePresetKey)
        let resolvedOfflinePreset = savedOfflinePresetStr.flatMap(YMAudioQualityPreset.init(rawValue:)) ?? .high320

        let allowedLimits: Set<Int> = [0, 2, 5, 10, 20]
        let resolvedOfflineLimit: Int
        if UserDefaults.standard.object(forKey: offlineCacheLimitKey) != nil {
            let savedOfflineLimit = UserDefaults.standard.integer(forKey: offlineCacheLimitKey)
            resolvedOfflineLimit = allowedLimits.contains(savedOfflineLimit) ? savedOfflineLimit : 5
        } else {
            resolvedOfflineLimit = 5
        }

        self.preset = resolvedPreset
        self.codecPreference = resolvedCodec
        self.preloadAllFavoritesInBackground = savedPreload
        self.imageCacheLimitMB = resolvedImageLimit
        self.crossfadeDuration = resolvedCrossfade
        self.offlineQualityPreset = resolvedOfflinePreset
        self.offlineCacheLimitGB = resolvedOfflineLimit

        ImagePipeline.shared.setMaxMemoryCost(mb: resolvedImageLimit)
    }

    public func setPreset(_ newPreset: YMAudioQualityPreset) {
        self.preset = newPreset
    }

    public func setCodecPreference(_ newCodec: YMAudioCodecPreference) {
        self.codecPreference = newCodec
    }

    public func setPreloadFavoritesInBackground(_ enabled: Bool) {
        self.preloadAllFavoritesInBackground = enabled
    }

    public func setImageCacheLimitMB(_ limit: Int) {
        self.imageCacheLimitMB = limit
    }

    public func setCrossfadeDuration(_ seconds: Double) {
        self.crossfadeDuration = max(0.0, min(12.0, seconds))
    }

    public func setOfflineQualityPreset(_ newPreset: YMAudioQualityPreset) {
        self.offlineQualityPreset = newPreset
    }

    public func setOfflineCacheLimitGB(_ limitGB: Int) {
        self.offlineCacheLimitGB = limitGB
    }

    /// Drops unnecessary cached data, trims search buffer and clears image/network caches to drop RAM to 40-50 MB
    public func purgeUnusedMemory() {
        LikesService.shared.compressMemory()
        ImagePipeline.shared.clearMemoryCache()
        YMBackdropBlurProcessor.shared.clearCache()
        Task {
            await YMNetworkClient.shared.clearCache()
        }
    }
}
