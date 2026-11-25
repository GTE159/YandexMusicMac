import Foundation
import Observation
import AppKit

/// Manages Yandex OAuth authentication and session persistence in macOS Keychain.
@Observable
@MainActor
public final class AuthService {
    public static let shared = AuthService()

    public private(set) var isAuthenticated: Bool = false
    public private(set) var isAuthenticating: Bool = false
    public private(set) var currentUser: YMAccountStatus?
    public private(set) var cachedEntitlement: OfflineEntitlementSnapshot? = nil
    public private(set) var deviceAuthState: YMDeviceAuthState = .idle
    public var errorMessage: String? = nil

    public var hasOfflinePlusEntitlement: Bool {
        if let user = currentUser {
            return user.hasActiveSubscription
        }
        if isAuthenticated,
           let ent = cachedEntitlement,
           ent.hasActiveSubscription,
           Date() < ent.validUntil {
            return true
        }
        return false
    }

    private let keychain: KeychainManager
    private let networkClient: YMNetworkClient
    @ObservationIgnored private let deviceAuthClient: YMDeviceAuthClient

    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var signOutTask: Task<Void, Never>?
    @ObservationIgnored private var deviceAuthTask: Task<Void, Never>?
    @ObservationIgnored private var deviceAuthGeneration: UInt64 = 0

    /// Official Yandex Music OAuth Client ID
    public static let oauthClientID = "23cabbbdc6cd418abb4b39c32c41195d"

    /// Strict canonical OAuth authorization URL specified for Yandex Music
    public static let oauthURLString = "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(oauthClientID)"

    /// Minimal OAuth scopes required strictly for Yandex Music playback, library, and likes/playlists
    public static let minimalOAuthScope = YMDeviceAuthClient.minimalMusicScopes

    private static let deviceIdDefaultsKey = "ym_oauth_device_id"

    public static func oauthAuthorizeURL(minimalScope: Bool = true, forceConfirm: Bool = true) -> URL? {
        var components = URLComponents(string: "https://oauth.yandex.ru/authorize")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: oauthClientID)
        ]
        if minimalScope {
            items.append(URLQueryItem(name: "scope", value: minimalOAuthScope))
        }
        if forceConfirm {
            items.append(URLQueryItem(name: "force_confirm", value: "yes"))
        }
        components?.queryItems = items
        return components?.url
    }

    public init(
        keychain: KeychainManager = .shared,
        networkClient: YMNetworkClient = .shared,
        deviceAuthClient: YMDeviceAuthClient = YMDeviceAuthClient()
    ) {
        self.keychain = keychain
        self.networkClient = networkClient
        self.deviceAuthClient = deviceAuthClient
        if let savedToken = keychain.getToken(), !savedToken.isEmpty {
            self.isAuthenticated = true
            let gen = self.sessionGeneration
            let savedUid = keychain.getUserId()
            if let uid = savedUid, !uid.isEmpty {
                SavedWavePresetStore.shared.loadIfNeeded(for: uid)
            }
            self.validationTask = Task { [weak self] in
                if let uid = savedUid, !uid.isEmpty {
                    let snapshot = await OfflineStorageStore.shared.loadEntitlement(for: uid)
                    await MainActor.run { [weak self] in
                        guard let self, self.sessionGeneration == gen else { return }
                        if self.cachedEntitlement == nil {
                            self.cachedEntitlement = snapshot
                        }
                    }
                }
                await OfflineDownloadManager.shared.loadIndexIfNeeded()
                await self?.validateSavedSession(expectedGeneration: gen)
            }
        }
    }

    // MARK: - Token Parsing, Sanitization & Extraction Utility

    /// Robustly extracts and sanitizes access_token from raw token string, full redirect URL, or fragment.
    public nonisolated static func extractToken(from rawInput: String) -> String {
        var trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("oauth ") {
            trimmed = String(trimmed.dropFirst("oauth ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.lowercased().hasPrefix("bearer ") {
            trimmed = String(trimmed.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return "" }

        var candidate = ""

        // 1. Check if string contains access_token= directly (in fragment, query or raw parameter)
        if let tokenRange = trimmed.range(of: "access_token=") {
            let substring = trimmed[tokenRange.upperBound...]
            let token = substring.prefix(while: { $0 != "&" && $0 != "#" && !$0.isWhitespace && $0 != "\"" && $0 != "'" })
            if !token.isEmpty {
                candidate = String(token)
            }
        }

        // 2. Fallback to URLComponents parsing
        if candidate.isEmpty, let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let fragment = components.fragment {
                let params = fragment.split(separator: "&")
                for param in params {
                    let pair = param.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 && pair[0] == "access_token" {
                        candidate = String(pair[1])
                        break
                    }
                }
            }

            if candidate.isEmpty, let tokenInQuery = components.queryItems?.first(where: { $0.name == "access_token" })?.value {
                candidate = tokenInQuery
            }
        }

        // 3. If user pasted a full URL without access_token=, reject it rather than treating URL as token
        if candidate.isEmpty {
            if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
                return ""
            }
            candidate = trimmed
        }

        // 4. Decode percent-encoding if any and strictly filter allowed OAuth token characters
        let decoded = candidate.removingPercentEncoding ?? candidate
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        let sanitized = decoded.unicodeScalars.filter { allowedChars.contains($0) }
        return String(String.UnicodeScalarView(sanitized))
    }

    // MARK: - Browser OAuth Navigation

    /// Opens the strict OAuth link in the user's default browser (Safari/Chrome) with explicit account confirmation
    public func openOAuthInBrowser() {
        guard let url = Self.oauthAuthorizeURL(minimalScope: true, forceConfirm: true) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Device Flow Authorization ("Вход как устройство")

    func stableDeviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIdDefaultsKey),
           existing.count >= 10 {
            return existing
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        var generated = String()
        generated.reserveCapacity(16)
        for _ in 0..<16 {
            let idx = Int.random(in: 0..<alphabet.count, using: &rng)
            generated.append(alphabet[idx])
        }
        UserDefaults.standard.set(generated, forKey: Self.deviceIdDefaultsKey)
        return generated
    }

    func deviceDisplayName() -> String {
        let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hostName, !hostName.isEmpty {
            return "flow~ (\(String(hostName.prefix(32))))"
        }
        return "flow~ (Mac)"
    }

    public func startDeviceAuth(preferMinimalScope: Bool = true) {
        deviceAuthTask?.cancel()
        deviceAuthTask = nil
        deviceAuthGeneration &+= 1
        let gen = deviceAuthGeneration

        self.errorMessage = nil
        self.deviceAuthState = .requestingCode

        let deviceId = stableDeviceId()
        let deviceName = deviceDisplayName()

        deviceAuthTask = Task { [weak self, deviceAuthClient] in
            guard let self else { return }

            let code: YMDeviceCodeResponse
            do {
                code = try await deviceAuthClient.requestDeviceCode(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    preferMinimalScope: preferMinimalScope
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }
                self.deviceAuthState = .failed(error.localizedDescription)
                return
            }

            guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }
            let expiresAt = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            self.deviceAuthState = .awaitingConfirmation(code: code, expiresAt: expiresAt)

            var pollInterval = TimeInterval(code.interval)
            var consecutiveNetworkErrors = 0

            while !Task.isCancelled && self.deviceAuthGeneration == gen {
                if Date() >= expiresAt {
                    self.deviceAuthState = .expired
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                } catch {
                    return
                }

                guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }

                do {
                    let result = try await deviceAuthClient.pollDeviceToken(deviceCode: code.deviceCode)
                    guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }

                    switch result {
                    case .pending:
                        consecutiveNetworkErrors = 0
                    case .slowDown:
                        consecutiveNetworkErrors = 0
                        pollInterval = min(pollInterval + 5.0, 20.0)
                    case .expired:
                        self.deviceAuthState = .expired
                        return
                    case .denied:
                        self.deviceAuthState = .failed(YMDeviceAuthError.accessDenied.localizedDescription)
                        return
                    case .authorized(let tokenResponse):
                        self.deviceAuthState = .verifyingToken
                        await self.performValidateAndSaveToken(tokenResponse.accessToken, cancelDeviceFlow: false)
                        guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }
                        if self.isAuthenticated {
                            self.deviceAuthState = .idle
                        } else {
                            self.deviceAuthState = .failed(self.errorMessage ?? "Не удалось проверить токен")
                        }
                        return
                    }
                } catch is CancellationError {
                    return
                } catch let authError as YMDeviceAuthError {
                    guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }
                    if case .networkError = authError {
                        consecutiveNetworkErrors += 1
                        if consecutiveNetworkErrors > 3 {
                            self.deviceAuthState = .failed(authError.localizedDescription)
                            return
                        }
                    } else {
                        self.deviceAuthState = .failed(authError.localizedDescription)
                        return
                    }
                } catch {
                    guard !Task.isCancelled, self.deviceAuthGeneration == gen else { return }
                    self.deviceAuthState = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    public func cancelDeviceAuth() {
        deviceAuthGeneration &+= 1
        deviceAuthTask?.cancel()
        deviceAuthTask = nil
        if deviceAuthState != .idle {
            deviceAuthState = .idle
        }
    }

    // MARK: - Method 2: Manual Token Submission

    public func submitManualToken(_ rawInput: String) async {
        let cleanToken = Self.extractToken(from: rawInput)
        guard cleanToken.count >= 10 else {
            self.errorMessage = "Некорректный формат токена. Вставьте OAuth-токен (например, y0_AgAAA...) или полную ссылку с #access_token=..."
            return
        }
        cancelDeviceAuth()
        await validateAndSaveToken(cleanToken)
    }

    // MARK: - Token Validation & Keychain Persistence

    public func validateAndSaveToken(_ token: String) async {
        await performValidateAndSaveToken(token, cancelDeviceFlow: true)
    }

    private func performValidateAndSaveToken(_ token: String, cancelDeviceFlow: Bool) async {
        if cancelDeviceFlow {
            cancelDeviceAuth()
        }
        validationTask?.cancel()
        validationTask = nil
        signOutTask?.cancel()
        signOutTask = nil
        sessionGeneration &+= 1
        let generation = sessionGeneration

        self.isAuthenticating = true
        self.errorMessage = nil

        // 1. Set token in network client temporarily to validate BEFORE saving to Keychain
        await networkClient.setToken(token)

        guard !Task.isCancelled, self.sessionGeneration == generation else { return }

        // 2. Validate token via GET https://api.music.yandex.net/account/status
        do {
            let status = try await networkClient.getAccountStatus()
            guard !Task.isCancelled, self.sessionGeneration == generation else { return }

            guard status.account?.registered != false,
                  (status.userId != nil || status.account?.login != nil) else {
                throw YMAPIError.unauthorized
            }

            // 3. Save verified token and userId into Keychain
            do {
                try keychain.saveToken(token)
            } catch {
                print("[AuthService] Warning: Failed to persist token in secure vault: \(error)")
                self.errorMessage = "Предупреждение: не удалось сохранить токен в защищённое хранилище (\(error.localizedDescription)). Сессия не сохранится после перезапуска."
            }
            if let uid = status.userId {
                try? keychain.saveUserId(uid)
                let snapshot = OfflineEntitlementSnapshot(from: status, userId: uid)
                self.cachedEntitlement = snapshot
                try? await OfflineStorageStore.shared.saveEntitlement(snapshot)
                await OfflineDownloadManager.shared.loadIndexIfNeeded()
                SavedWavePresetStore.shared.loadIfNeeded(for: uid)
                try? await LikesService.shared.syncLikes(uid: uid)
            }

            guard !Task.isCancelled, self.sessionGeneration == generation else { return }

            self.currentUser = status
            self.isAuthenticated = true
            self.isAuthenticating = false
            AudioPlayerEngine.shared.checkSubscriptionEligibility()
        } catch {
            guard !Task.isCancelled, self.sessionGeneration == generation else { return }

            // Rollback token in network client if validation failed
            let previousValidToken = keychain.getToken()
            if self.sessionGeneration == generation {
                await networkClient.setToken(previousValidToken)
            }
            self.isAuthenticating = false
            self.errorMessage = "Ошибка проверки токена: \(error.localizedDescription)"
        }
    }

    public func validateSavedSession() async {
        validationTask?.cancel()
        sessionGeneration &+= 1
        let gen = sessionGeneration
        await validateSavedSession(expectedGeneration: gen)
    }

    private func validateSavedSession(expectedGeneration: UInt64) async {
        guard let token = keychain.getToken(), !token.isEmpty else {
            guard !Task.isCancelled, self.sessionGeneration == expectedGeneration else { return }
            self.isAuthenticated = false
            return
        }

        await networkClient.setToken(token)

        guard !Task.isCancelled, self.sessionGeneration == expectedGeneration else { return }

        do {
            let status = try await networkClient.getAccountStatus()
            guard !Task.isCancelled, self.sessionGeneration == expectedGeneration else { return }

            guard status.account?.registered != false,
                  (status.userId != nil || status.account?.login != nil) else {
                self.signOut()
                return
            }

            self.currentUser = status
            self.isAuthenticated = true

            if let uid = status.userId {
                try? keychain.saveUserId(uid)
                let snapshot = OfflineEntitlementSnapshot(from: status, userId: uid)
                self.cachedEntitlement = snapshot
                try? await OfflineStorageStore.shared.saveEntitlement(snapshot)
                await OfflineDownloadManager.shared.loadIndexIfNeeded()
                SavedWavePresetStore.shared.loadIfNeeded(for: uid)
                try? await LikesService.shared.syncLikes(uid: uid)
            }

            AudioPlayerEngine.shared.checkSubscriptionEligibility()
        } catch let apiError as YMAPIError {
            guard !Task.isCancelled, self.sessionGeneration == expectedGeneration else { return }
            if case .unauthorized = apiError {
                print("[AuthService] Saved token is unauthorized (401). Signing out.")
                if self.sessionGeneration == expectedGeneration {
                    self.signOut()
                }
            } else {
                print("[AuthService] Saved session network warning (offline?): \(apiError)")
            }
        } catch {
            guard !Task.isCancelled, self.sessionGeneration == expectedGeneration else { return }
            print("[AuthService] Saved session validation error: \(error)")
        }
    }

    public func signOut() {
        cancelDeviceAuth()
        sessionGeneration &+= 1
        let generation = sessionGeneration

        validationTask?.cancel()
        validationTask = nil
        signOutTask?.cancel()

        // Останавливаем воспроизведение и очищаем системный плеер
        AudioPlayerEngine.shared.stopAndClear()
        NowPlayingController.shared.clearNowPlaying()
        LikesService.shared.resetAll()
        PlaylistsService.shared.resetAll()
        OfflineDownloadManager.shared.resetForSignOut()
        SavedWavePresetStore.shared.resetInMemory()
        WaveSessionController.shared.clearActiveSavedWave()
        self.cachedEntitlement = nil

        try? keychain.clearAll()

        signOutTask = Task { [weak self, networkClient] in
            await OfflineStorageStore.shared.clearEntitlement()
            await RotorService.shared.resetSession()
            guard let self = self else { return }
            let stillMatches = await MainActor.run {
                self.sessionGeneration == generation
            }
            if stillMatches {
                await networkClient.setToken(nil)
                await networkClient.clearCache()
            }
        }

        self.currentUser = nil
        self.errorMessage = nil
        self.isAuthenticated = false
    }
}
