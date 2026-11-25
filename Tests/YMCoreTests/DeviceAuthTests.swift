import Testing
import Foundation
@testable import YMCore

private final class MockDeviceAuthURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let bodyData = Self.readBody(from: request)
        do {
            let (status, data) = try handler(request, bodyData)
            let url = request.url ?? URL(string: "https://oauth.yandex.ru")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let direct = request.httpBody {
            return direct
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let readCount = stream.read(&buffer, maxLength: buffer.count)
            if readCount > 0 {
                collected.append(buffer, count: readCount)
            } else {
                break
            }
        }
        return collected
    }
}

private final class LockedRecorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ value: T) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

@Suite("OAuth Minimal Scope & Device Auth Flow Tests", .serialized)
struct DeviceAuthTests {

    private func makeMockClient() -> YMDeviceAuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockDeviceAuthURLProtocol.self]
        let session = URLSession(configuration: config)
        return YMDeviceAuthClient(customSession: session)
    }

    @Test("requestDeviceCode sends minimal scope first and returns usedMinimalScope == true on HTTP 200")
    func testRequestDeviceCodeMinimalScopeSuccess() async throws {
        defer { MockDeviceAuthURLProtocol.handler = nil }

        let capturedBodies = LockedRecorder<String>()
        MockDeviceAuthURLProtocol.handler = { request, bodyData in
            #expect(request.url?.path == "/device/code")
            #expect(request.httpMethod == "POST")
            let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
            capturedBodies.append(bodyStr)

            let payload = """
            {
                "device_code": "dev-123",
                "user_code": "ABCD-1234",
                "verification_url": "https://ya.ru/device",
                "interval": 5,
                "expires_in": 300
            }
            """.data(using: .utf8)!
            return (200, payload)
        }

        let client = makeMockClient()
        let response = try await client.requestDeviceCode(
            deviceId: "device-id-0001",
            deviceName: "flow~ (Mac)",
            preferMinimalScope: true
        )

        #expect(response.deviceCode == "dev-123")
        #expect(response.userCode == "ABCD-1234")
        #expect(response.verificationUrl == "https://ya.ru/device")
        #expect(response.interval == 5)
        #expect(response.expiresIn == 300)
        #expect(response.usedMinimalScope == true)

        let bodies = capturedBodies.snapshot()
        #expect(bodies.count == 1)
        let decoded = bodies[0].removingPercentEncoding ?? bodies[0]
        #expect(decoded.contains("scope=music:content music:read music:write"))
    }

    @Test("requestDeviceCode falls back without scope on HTTP 400 invalid_scope and marks usedMinimalScope == false")
    func testRequestDeviceCodeInvalidScopeFallback() async throws {
        defer { MockDeviceAuthURLProtocol.handler = nil }

        let capturedBodies = LockedRecorder<String>()
        MockDeviceAuthURLProtocol.handler = { _, bodyData in
            let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
            capturedBodies.append(bodyStr)

            if capturedBodies.snapshot().count == 1 {
                let errJSON = """
                {
                    "error": "invalid_scope",
                    "error_description": "Requested scope is not allowed for this client"
                }
                """.data(using: .utf8)!
                return (400, errJSON)
            } else {
                let okJSON = """
                {
                    "device_code": "dev-fallback",
                    "user_code": "WXYZ-5678",
                    "verification_url": "https://ya.ru/device",
                    "interval": 6,
                    "expires_in": 600
                }
                """.data(using: .utf8)!
                return (200, okJSON)
            }
        }

        let client = makeMockClient()
        let response = try await client.requestDeviceCode(
            deviceId: "device-id-0002",
            deviceName: "flow~ (Mac)",
            preferMinimalScope: true
        )

        #expect(response.deviceCode == "dev-fallback")
        #expect(response.userCode == "WXYZ-5678")
        #expect(response.usedMinimalScope == false)

        let bodies = capturedBodies.snapshot()
        #expect(bodies.count == 2)
        let firstDecoded = bodies[0].removingPercentEncoding ?? bodies[0]
        let secondDecoded = bodies[1].removingPercentEncoding ?? bodies[1]
        #expect(firstDecoded.contains("scope=music:content music:read music:write"))
        #expect(!secondDecoded.contains("scope="))
    }

    @Test("pollDeviceToken maps authorized, pending, slowDown, expired, and denied responses")
    func testPollDeviceTokenMappings() async throws {
        defer { MockDeviceAuthURLProtocol.handler = nil }
        let client = makeMockClient()

        // 1. HTTP 200 -> .authorized
        MockDeviceAuthURLProtocol.handler = { request, _ in
            #expect(request.url?.path == "/token")
            let json = """
            {
                "access_token": "y0_sample_device_token",
                "token_type": "bearer",
                "expires_in": 31536000,
                "refresh_token": "r_sample"
            }
            """.data(using: .utf8)!
            return (200, json)
        }
        let authorized = try await client.pollDeviceToken(deviceCode: "dev-code")
        #expect(authorized == .authorized(YMOAuthTokenResponse(
            accessToken: "y0_sample_device_token",
            tokenType: "bearer",
            expiresIn: 31536000,
            refreshToken: "r_sample"
        )))

        // 2. HTTP 400 authorization_pending -> .pending
        MockDeviceAuthURLProtocol.handler = { _, _ in
            (400, Data("{\"error\":\"authorization_pending\"}".utf8))
        }
        #expect(try await client.pollDeviceToken(deviceCode: "dev-code") == .pending)

        // 3. HTTP 400 slow_down -> .slowDown
        MockDeviceAuthURLProtocol.handler = { _, _ in
            (400, Data("{\"error\":\"slow_down\"}".utf8))
        }
        #expect(try await client.pollDeviceToken(deviceCode: "dev-code") == .slowDown)

        // 4. HTTP 400 expired_token -> .expired
        MockDeviceAuthURLProtocol.handler = { _, _ in
            (400, Data("{\"error\":\"expired_token\"}".utf8))
        }
        #expect(try await client.pollDeviceToken(deviceCode: "dev-code") == .expired)

        // 5. HTTP 400 access_denied -> .denied
        MockDeviceAuthURLProtocol.handler = { _, _ in
            (400, Data("{\"error\":\"access_denied\"}".utf8))
        }
        #expect(try await client.pollDeviceToken(deviceCode: "dev-code") == .denied)
    }

    @Test("AuthService.oauthAuthorizeURL formats minimal scope toggle and preserves stable device_id")
    @MainActor
    func testOAuthAuthorizeURLAndStableDeviceId() throws {
        let minURL = try #require(AuthService.oauthAuthorizeURL(minimalScope: true, forceConfirm: true))
        let minComponents = try #require(URLComponents(url: minURL, resolvingAgainstBaseURL: false))
        let minItems = minComponents.queryItems ?? []
        #expect(minItems.first(where: { $0.name == "client_id" })?.value == AuthService.oauthClientID)
        #expect(minItems.first(where: { $0.name == "response_type" })?.value == "token")
        #expect(minItems.first(where: { $0.name == "scope" })?.value == "music:content music:read music:write")
        #expect(minItems.first(where: { $0.name == "force_confirm" })?.value == "yes")

        let fallbackURL = try #require(AuthService.oauthAuthorizeURL(minimalScope: false, forceConfirm: false))
        let fallbackComponents = try #require(URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false))
        let fallbackItems = fallbackComponents.queryItems ?? []
        #expect(fallbackItems.first(where: { $0.name == "scope" }) == nil)
        #expect(fallbackItems.first(where: { $0.name == "force_confirm" }) == nil)

        // Stable device_id persistence test (restore original defaults cleanly)
        let key = "ym_oauth_device_id"
        let prev = UserDefaults.standard.object(forKey: key)
        defer {
            if let prev { UserDefaults.standard.set(prev, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let keychain = KeychainManager(service: "com.yandexmusic.mac.tests.\(UUID().uuidString)")
        let auth = AuthService(keychain: keychain)
        let firstId = auth.stableDeviceId()
        let secondId = auth.stableDeviceId()
        #expect(firstId.count >= 16)
        #expect(firstId == secondId)
        #expect(UserDefaults.standard.string(forKey: key) == firstId)
    }
}
