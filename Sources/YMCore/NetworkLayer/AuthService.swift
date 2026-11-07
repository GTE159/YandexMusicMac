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
    public var errorMessage: String? = nil

    private let keychain: KeychainManager
    private let networkClient: YMNetworkClient

    /// Official Yandex Music OAuth Client ID
    public static let oauthClientID = "23cabbbdc6cd418abb4b39c32c41195d"

    /// Strict canonical OAuth authorization URL specified for Yandex Music
    public static let oauthURLString = "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(oauthClientID)"

    public init(keychain: KeychainManager = .shared, networkClient: YMNetworkClient = .shared) {
        self.keychain = keychain
        self.networkClient = networkClient
        if let savedToken = keychain.getToken(), !savedToken.isEmpty {
            self.isAuthenticated = true
            Task {
                await self.validateSavedSession()
            }
        }
    }

    // MARK: - Token Parsing, Sanitization & Extraction Utility

    /// Robustly extracts and sanitizes access_token from raw token string, full redirect URL, or fragment.
    public static func extractToken(from rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let url = URL(string: "\(Self.oauthURLString)&force_confirm=yes") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Method 2: Manual Token Submission

    public func submitManualToken(_ rawInput: String) async {
        let cleanToken = Self.extractToken(from: rawInput)
        guard cleanToken.count >= 10 else {
            self.errorMessage = "Некорректный формат токена. Вставьте OAuth-токен (например, y0_AgAAA...) или полную ссылку с #access_token=..."
            return
        }
        await validateAndSaveToken(cleanToken)
    }

    // MARK: - Token Validation & Keychain Persistence

    public func validateAndSaveToken(_ token: String) async {
        self.isAuthenticating = true
        self.errorMessage = nil

        // 1. Set token in network client temporarily to validate BEFORE saving to Keychain
        await networkClient.setToken(token)

        // 2. Validate token via GET https://api.music.yandex.net/account/status
        do {
            let status = try await networkClient.getAccountStatus()
            guard status.userId != nil || status.account?.login != nil else {
                throw YMAPIError.unauthorized
            }

            // 3. Save verified token and userId into Keychain
            do {
                try keychain.saveToken(token)
            } catch {
                print("[AuthService] Warning: Failed to persist token in Keychain: \(error)")
                self.errorMessage = "Предупреждение: не удалось сохранить токен в Связку ключей (\(error.localizedDescription)). Сессия не сохранится после перезапуска."
            }
            if let uid = status.userId {
                try? keychain.saveUserId(uid)
                try? await LikesService.shared.syncLikes(uid: uid)
            }

            self.currentUser = status
            self.isAuthenticated = true
            self.isAuthenticating = false
        } catch {
            // Rollback token in network client if validation failed
            let previousValidToken = keychain.getToken()
            await networkClient.setToken(previousValidToken)
            self.isAuthenticating = false
            self.errorMessage = "Ошибка проверки токена: \(error.localizedDescription)"
        }
    }

    public func validateSavedSession() async {
        guard let token = keychain.getToken(), !token.isEmpty else {
            self.isAuthenticated = false
            return
        }

        await networkClient.setToken(token)

        do {
            let status = try await networkClient.getAccountStatus()
            self.currentUser = status
            self.isAuthenticated = true
            if let uid = status.userId {
                try? keychain.saveUserId(uid)
                try? await LikesService.shared.syncLikes(uid: uid)
            }
        } catch let apiError as YMAPIError {
            if case .unauthorized = apiError {
                print("[AuthService] Saved token is unauthorized (401). Signing out.")
                self.signOut()
            } else {
                print("[AuthService] Saved session network warning (offline?): \(apiError)")
            }
        } catch {
            print("[AuthService] Saved session validation error: \(error)")
        }
    }

    public func signOut() {
        // Останавливаем воспроизведение и очищаем системный плеер
        AudioPlayerEngine.shared.stopAndClear()
        NowPlayingController.shared.clearNowPlaying()
        LikesService.shared.resetAll()

        try? keychain.clearAll()
        Task {
            await RotorService.shared.resetSession()
            await networkClient.setToken(nil)
            await networkClient.clearCache()
        }
        self.currentUser = nil
        self.errorMessage = nil
        self.isAuthenticated = false
    }
}
