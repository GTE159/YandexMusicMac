import Foundation

// MARK: - Device Flow Models

public struct YMDeviceCodeResponse: Decodable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUrl: String
    public let interval: Int
    public let expiresIn: Int
    public let usedMinimalScope: Bool

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case interval
        case expiresIn = "expires_in"
    }

    public init(
        deviceCode: String,
        userCode: String,
        verificationUrl: String,
        interval: Int = 5,
        expiresIn: Int = 300,
        usedMinimalScope: Bool = true
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUrl = verificationUrl
        self.interval = max(2, interval)
        self.expiresIn = max(30, expiresIn)
        self.usedMinimalScope = usedMinimalScope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceCode = try c.decode(String.self, forKey: .deviceCode)
        self.userCode = try c.decode(String.self, forKey: .userCode)
        self.verificationUrl = try c.decode(String.self, forKey: .verificationUrl)
        let rawInterval = (try? c.decodeIfPresent(Int.self, forKey: .interval)) ?? 5
        let rawExpires = (try? c.decodeIfPresent(Int.self, forKey: .expiresIn)) ?? 300
        self.interval = max(2, rawInterval)
        self.expiresIn = max(30, rawExpires)
        self.usedMinimalScope = true
    }

    public func withUsedMinimalScope(_ flag: Bool) -> YMDeviceCodeResponse {
        YMDeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUrl: verificationUrl,
            interval: interval,
            expiresIn: expiresIn,
            usedMinimalScope: flag
        )
    }
}

public struct YMOAuthTokenResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String?
    public let expiresIn: Int?
    public let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }

    public init(
        accessToken: String,
        tokenType: String? = nil,
        expiresIn: Int? = nil,
        refreshToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }
}

public struct YMOAuthErrorPayload: Decodable, Sendable {
    public let error: String?
    public let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

public enum YMDevicePollResult: Sendable, Equatable {
    case authorized(YMOAuthTokenResponse)
    case pending
    case slowDown
    case expired
    case denied
}

public enum YMDeviceAuthError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case invalidScope
    case expired
    case accessDenied
    case serverError(code: String, description: String?)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Некорректный адрес сервера авторизации."
        case .invalidScope:
            return "Сервер отклонил ограниченный набор прав."
        case .expired:
            return "Срок действия кода истёк. Запросите новый код."
        case .accessDenied:
            return "Вход отклонён на странице подтверждения."
        case .serverError(let code, let description):
            if let description, !description.isEmpty {
                return "Ошибка Яндекс OAuth (\(code)): \(description)"
            }
            return "Ошибка Яндекс OAuth: \(code)"
        case .networkError(let msg):
            return "Ошибка сети: \(msg)"
        }
    }
}

public enum YMDeviceAuthState: Sendable, Equatable {
    case idle
    case requestingCode
    case awaitingConfirmation(code: YMDeviceCodeResponse, expiresAt: Date)
    case verifyingToken
    case expired
    case failed(String)
}

// MARK: - Device Auth Client

/// Actor encapsulating Yandex OAuth 2.0 Device Flow (`POST /device/code` & `POST /token`)
/// with automatic `invalid_scope` fallback and isolated ephemeral `URLSession`.
public actor YMDeviceAuthClient {
    public static let oauthBaseURL = URL(string: "https://oauth.yandex.ru")!
    public static let defaultClientID = "23cabbbdc6cd418abb4b39c32c41195d"
    public static let defaultClientSecret = "53bc75238f0c4d08a118e51fe9203300"
    public static let minimalMusicScopes = "music:content music:read music:write"

    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(customSession: URLSession? = nil) {
        if let customSession {
            self.session = customSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    public func requestDeviceCode(
        deviceId: String,
        deviceName: String,
        clientId: String = defaultClientID,
        preferMinimalScope: Bool = true
    ) async throws -> YMDeviceCodeResponse {
        if preferMinimalScope {
            do {
                return try await performDeviceCodeRequest(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    clientId: clientId,
                    scope: Self.minimalMusicScopes
                )
            } catch YMDeviceAuthError.invalidScope {
                return try await performDeviceCodeRequest(
                    deviceId: deviceId,
                    deviceName: deviceName,
                    clientId: clientId,
                    scope: nil
                )
            }
        }

        return try await performDeviceCodeRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            clientId: clientId,
            scope: nil
        )
    }

    public func pollDeviceToken(
        deviceCode: String,
        clientId: String = defaultClientID,
        clientSecret: String = defaultClientSecret
    ) async throws -> YMDevicePollResult {
        let endpoint = Self.oauthBaseURL.appendingPathComponent("token")
        let body = formEncodedBody([
            ("grant_type", "device_code"),
            ("code", deviceCode),
            ("client_id", clientId),
            ("client_secret", clientSecret)
        ])

        let (data, httpResponse) = try await executeFormPost(to: endpoint, body: body)
        let status = httpResponse.statusCode

        if (200...299).contains(status) {
            do {
                let tokenResponse = try decoder.decode(YMOAuthTokenResponse.self, from: data)
                return .authorized(tokenResponse)
            } catch {
                throw YMDeviceAuthError.serverError(
                    code: "decoding_error",
                    description: error.localizedDescription
                )
            }
        }

        let errorPayload = try? decoder.decode(YMOAuthErrorPayload.self, from: data)
        let errorCode = errorPayload?.error?.lowercased() ?? ""

        switch errorCode {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token":
            return .expired
        case "access_denied":
            return .denied
        case "invalid_scope":
            throw YMDeviceAuthError.invalidScope
        default:
            throw YMDeviceAuthError.serverError(
                code: errorPayload?.error ?? "http_\(status)",
                description: errorPayload?.errorDescription
            )
        }
    }

    // MARK: - Internal Helpers

    private func performDeviceCodeRequest(
        deviceId: String,
        deviceName: String,
        clientId: String,
        scope: String?
    ) async throws -> YMDeviceCodeResponse {
        let endpoint = Self.oauthBaseURL.appendingPathComponent("device/code")
        var pairs: [(String, String)] = [
            ("client_id", clientId),
            ("device_id", deviceId),
            ("device_name", deviceName)
        ]
        if let scope, !scope.isEmpty {
            pairs.append(("scope", scope))
        }

        let (data, httpResponse) = try await executeFormPost(to: endpoint, body: formEncodedBody(pairs))
        let status = httpResponse.statusCode

        if (200...299).contains(status) {
            do {
                let decoded = try decoder.decode(YMDeviceCodeResponse.self, from: data)
                return decoded.withUsedMinimalScope(scope != nil)
            } catch {
                throw YMDeviceAuthError.serverError(
                    code: "decoding_error",
                    description: error.localizedDescription
                )
            }
        }

        let errorPayload = try? decoder.decode(YMOAuthErrorPayload.self, from: data)
        if errorPayload?.error?.lowercased() == "invalid_scope" {
            throw YMDeviceAuthError.invalidScope
        }
        throw YMDeviceAuthError.serverError(
            code: errorPayload?.error ?? "http_\(status)",
            description: errorPayload?.errorDescription
        )
    }

    private func executeFormPost(to url: URL, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw YMDeviceAuthError.networkError("Некорректный HTTP-ответ сервера.")
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let authError as YMDeviceAuthError {
            throw authError
        } catch {
            throw YMDeviceAuthError.networkError(error.localizedDescription)
        }
    }

    private func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        let rfc3986Unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
