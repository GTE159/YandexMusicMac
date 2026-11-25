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
    private let offlineCacheCustomEnabledKey = "ym_offline_cache_custom_enabled"
    private let offlineCacheCustomLimitGBKey = "ym_offline_cache_custom_gb"
    private let outputDeviceUIDKey = "ym_audio_output_device_uid"
    private let autoSampleRateKey = "ym_audio_auto_sample_rate"
    private let exclusiveHogModeKey = "ym_audio_exclusive_hog_mode"
    private let bitPerfectFixedVolumeKey = "ym_audio_bit_perfect_fixed_volume"

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

    /// Maximum disk quota preset for offline downloaded tracks in GB (`0` = unlimited, default `5`)
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

    /// Enables manual custom offline cache disk quota (`offlineCacheCustomLimitGB`) instead of preset
    public var offlineCacheCustomLimitEnabled: Bool {
        didSet {
            UserDefaults.standard.set(offlineCacheCustomLimitEnabled, forKey: offlineCacheCustomEnabledKey)
        }
    }

    /// User-entered custom disk quota in GB (`0.1...500.0`, default `10.0`)
    public var offlineCacheCustomLimitGB: Double {
        didSet {
            let clamped = Self.normalizedCustomCacheLimitGB(offlineCacheCustomLimitGB)
            if abs(offlineCacheCustomLimitGB - clamped) > 0.0001 {
                offlineCacheCustomLimitGB = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: offlineCacheCustomLimitGBKey)
        }
    }

    /// Effective byte quota enforced by `OfflineDownloadManager` (`0` = unlimited).
    public var effectiveOfflineCacheLimitBytes: Int64 {
        if offlineCacheCustomLimitEnabled {
            let gb = Self.normalizedCustomCacheLimitGB(offlineCacheCustomLimitGB)
            return Int64((gb * 1_073_741_824.0).rounded())
        }
        if offlineCacheLimitGB > 0 {
            return Int64(offlineCacheLimitGB) * 1_073_741_824
        }
        return 0
    }

    /// Human-readable label for the active offline disk limit.
    public var effectiveOfflineCacheLimitDisplay: String {
        if offlineCacheCustomLimitEnabled {
            return Self.formatLimitGB(offlineCacheCustomLimitGB)
        }
        if offlineCacheLimitGB == 0 {
            return "Без лимита"
        }
        return "\(offlineCacheLimitGB) ГБ"
    }

    public static func normalizedCustomCacheLimitGB(_ value: Double) -> Double {
        guard value.isFinite && value > 0 else { return 10.0 }
        let clamped = max(0.1, min(500.0, value))
        return (clamped * 100.0).rounded() / 100.0
    }

    public static func parseCustomCacheLimitGB(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "гб", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "gb", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let parsed = Double(cleaned), parsed.isFinite, parsed > 0 else {
            return nil
        }
        return normalizedCustomCacheLimitGB(parsed)
    }

    public static func formatLimitGB(_ gb: Double) -> String {
        let normalized = normalizedCustomCacheLimitGB(gb)
        let roundedInt = normalized.rounded()
        if abs(normalized - roundedInt) < 0.005 {
            return "\(Int(roundedInt)) ГБ"
        }
        let oneDecimal = (normalized * 10.0).rounded() / 10.0
        if abs(normalized - oneDecimal) < 0.005 {
            return String(format: "%.1f ГБ", oneDecimal)
        }
        return String(format: "%.2f ГБ", normalized)
    }

    /// Preferred output audio device UID (`""` = System Default Output)
    public var audioOutputDeviceUID: String {
        didSet {
            UserDefaults.standard.set(audioOutputDeviceUID, forKey: outputDeviceUIDKey)
            guard oldValue != audioOutputDeviceUID else { return }
            NotificationCenter.default.post(name: .ymAudioOutputSettingsDidChange, object: nil)
        }
    }

    /// Automatically switches hardware DAC nominal sample rate to match source audio tracks
    public var autoSampleRateSwitching: Bool {
        didSet {
            UserDefaults.standard.set(autoSampleRateSwitching, forKey: autoSampleRateKey)
            guard oldValue != autoSampleRateSwitching else { return }
            NotificationCenter.default.post(name: .ymAudioOutputSettingsDidChange, object: nil)
        }
    }

    /// Enables CoreAudio HAL Exclusive (Hog) mode bypassing macOS CoreAudio mixer & EQ
    public var exclusiveHogMode: Bool {
        didSet {
            UserDefaults.standard.set(exclusiveHogMode, forKey: exclusiveHogModeKey)
            guard oldValue != exclusiveHogMode else { return }
            NotificationCenter.default.post(name: .ymAudioOutputSettingsDidChange, object: nil)
        }
    }

    /// Fixes software gain at unity (0 dB / no sample multiplication) when Hog Mode is active
    public var bitPerfectFixedVolume: Bool {
        didSet {
            UserDefaults.standard.set(bitPerfectFixedVolume, forKey: bitPerfectFixedVolumeKey)
            guard oldValue != bitPerfectFixedVolume else { return }
            NotificationCenter.default.post(name: .ymAudioOutputSettingsDidChange, object: nil)
        }
    }

    public var usesDirectHALBackend: Bool {
        exclusiveHogMode || autoSampleRateSwitching || !audioOutputDeviceUID.isEmpty
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

        let savedCustomLimitEnabled = UserDefaults.standard.bool(forKey: offlineCacheCustomEnabledKey)
        let resolvedCustomLimitGB: Double
        if UserDefaults.standard.object(forKey: offlineCacheCustomLimitGBKey) != nil {
            resolvedCustomLimitGB = Self.normalizedCustomCacheLimitGB(UserDefaults.standard.double(forKey: offlineCacheCustomLimitGBKey))
        } else {
            resolvedCustomLimitGB = 10.0
        }

        let savedDeviceUID = UserDefaults.standard.string(forKey: outputDeviceUIDKey) ?? ""
        let savedAutoSampleRate = UserDefaults.standard.bool(forKey: autoSampleRateKey)
        let savedExclusiveHog = UserDefaults.standard.bool(forKey: exclusiveHogModeKey)
        let savedFixedVol: Bool
        if UserDefaults.standard.object(forKey: bitPerfectFixedVolumeKey) != nil {
            savedFixedVol = UserDefaults.standard.bool(forKey: bitPerfectFixedVolumeKey)
        } else {
            savedFixedVol = true
        }

        self.preset = resolvedPreset
        self.codecPreference = resolvedCodec
        self.preloadAllFavoritesInBackground = savedPreload
        self.imageCacheLimitMB = resolvedImageLimit
        self.crossfadeDuration = resolvedCrossfade
        self.offlineQualityPreset = resolvedOfflinePreset
        self.offlineCacheLimitGB = resolvedOfflineLimit
        self.offlineCacheCustomLimitEnabled = savedCustomLimitEnabled
        self.offlineCacheCustomLimitGB = resolvedCustomLimitGB
        self.audioOutputDeviceUID = savedDeviceUID
        self.autoSampleRateSwitching = savedAutoSampleRate
        self.exclusiveHogMode = savedExclusiveHog
        self.bitPerfectFixedVolume = savedFixedVol

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

    public func setOfflineCacheCustomLimitEnabled(_ enabled: Bool) {
        self.offlineCacheCustomLimitEnabled = enabled
    }

    public func setOfflineCacheCustomLimitGB(_ limitGB: Double) {
        self.offlineCacheCustomLimitGB = limitGB
    }

    public func setAudioOutputDeviceUID(_ uid: String) {
        self.audioOutputDeviceUID = uid
    }

    public func setAutoSampleRateSwitching(_ enabled: Bool) {
        self.autoSampleRateSwitching = enabled
    }

    public func setExclusiveHogMode(_ enabled: Bool) {
        self.exclusiveHogMode = enabled
    }

    public func setBitPerfectFixedVolume(_ enabled: Bool) {
        self.bitPerfectFixedVolume = enabled
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

public extension Notification.Name {
    static let ymAudioOutputSettingsDidChange = Notification.Name("ymAudioOutputSettingsDidChange")
}
