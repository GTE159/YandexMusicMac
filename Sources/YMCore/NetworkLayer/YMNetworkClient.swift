import Foundation

/// Actor responsible for all Yandex Music API network communication.
/// Configured with bounded memory cache (4 MB RAM / 20 MB disk) to meet strict macOS RAM budget.
public actor YMNetworkClient {
    public static let shared = YMNetworkClient()

    private let session: URLSession
    private let baseURL: URL
    private var token: String?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private struct CachedStreamInfos {
        let timestamp: Date
        let infos: [YMDownloadInfo]
    }
    private var streamInfosCache: [String: CachedStreamInfos] = [:]
    private let streamCacheTTL: TimeInterval = 120 // 2 минуты
    /// Bounded in-memory LRC cache (max 12 tracks) so switching lyrics display modes is instant
    private var lyricsLRCCache: [String: YMSyncedLyrics] = [:]
    private var lyricsLRCCacheOrder: [String] = []

    public static let userAgent = "Yandex-Music-API"
    public static let clientHeader = "YandexMusicAndroid/24023621"
    public static let acceptLanguage = "ru"

    /// Безопасное экранирование сегментов URL-пути
    public nonisolated static func escapePath(_ segment: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    public init(
        baseURL: URL = URL(string: "https://api.music.yandex.net")!,
        token: String? = nil,
        customSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.token = token ?? KeychainManager.shared.getToken()

        if let customSession = customSession {
            self.session = customSession
        } else {
            let cache = URLCache(
                memoryCapacity: 4 * 1024 * 1024,   // 4 MB RAM limit
                diskCapacity: 20 * 1024 * 1024,    // 20 MB disk limit
                diskPath: "ym_network_cache"
            )
            let config = URLSessionConfiguration.default
            config.urlCache = cache
            config.requestCachePolicy = .useProtocolCachePolicy
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Token Management

    public func setToken(_ newToken: String?) {
        self.token = newToken
    }

    public func currentToken() -> String? {
        self.token
    }

    // MARK: - Core Request Pipeline

    /// Executes request, parses standard { invocationInfo, result, error } envelope and unwraps result.
    public func request<T: Decodable & Sendable>(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> T {
        let (data, _) = try await performRawRequest(
            endpoint: endpoint,
            method: method,
            queryItems: queryItems,
            body: body,
            headers: headers,
            cachePolicy: cachePolicy
        )

        do {
            let envelope: YMResponse<T> = try autoreleasepool {
                try decoder.decode(YMResponse<T>.self, from: data)
            }
            return try envelope.unwrap()
        } catch let apiError as YMAPIError {
            throw apiError
        } catch {
            // Attempt decoding direct T in case an endpoint returns unwrapped result
            if let directResult = try? autoreleasepool(invoking: { try decoder.decode(T.self, from: data) }) {
                return directResult
            }
            throw YMAPIError.decodingError("Failed to parse \(T.self): \(error.localizedDescription)")
        }
    }

    /// Performs raw HTTP request with standard Yandex Music headers
    public func performRawRequest(
        endpoint: String,
        method: String = "GET",
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        headers: [String: String]? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> (Data, HTTPURLResponse) {
        let urlString: String
        if endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://") {
            urlString = endpoint
        } else {
            let cleanBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanPath = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
            urlString = cleanBase + cleanPath
        }

        guard var components = URLComponents(string: urlString) else {
            throw YMAPIError.invalidURL(urlString)
        }

        if let queryItems = queryItems, !queryItems.isEmpty {
            var existingItems = components.queryItems ?? []
            existingItems.append(contentsOf: queryItems)

            // Percent-encode query item names and values strictly using RFC 3986 unreserved: alphanumerics and "-._~".
            let rfc3986Unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            var queryParts: [String] = []
            for item in existingItems {
                let name = item.name.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? item.name
                let value = item.value?.addingPercentEncoding(withAllowedCharacters: rfc3986Unreserved) ?? ""
                queryParts.append("\(name)=\(value)")
            }
            components.percentEncodedQuery = queryParts.joined(separator: "&")
        }

        guard let finalURL = components.url else {
            throw YMAPIError.invalidURL(urlString)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = cachePolicy

        // Mandatory headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")

        let isTrustedAPIHost = finalURL.scheme?.lowercased() == "https" &&
                               finalURL.host?.lowercased() == baseURL.host?.lowercased()

        if isTrustedAPIHost {
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(Self.clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
            if let token = self.token, !token.isEmpty {
                request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        if body != nil && request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if let customHeaders = headers {
            for (key, val) in customHeaders {
                request.setValue(val, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YMAPIError.httpError(statusCode: -1, data: data)
        }

        if httpResponse.statusCode == 401 {
            throw YMAPIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw YMAPIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }

        return (data, httpResponse)
    }

    // MARK: - Audio Stream Extraction (2-step algorithm)

    /// Step 1: GET /tracks/{trackId}/download-info -> Pick MP3 320kbps
    public func getDownloadInfo(for trackId: String) async throws -> [YMDownloadInfo] {
        let cleanTrackId = trackId.components(separatedBy: ":").first ?? trackId
        return try await request(endpoint: "/tracks/\(Self.escapePath(cleanTrackId))/download-info")
    }

    /// Step 2: GET {downloadInfoUrl}&format=json -> Parse host, path, ts, s
    public func fetchStreamData(from downloadInfoURL: URL) async throws -> YMStreamData {
        var components = URLComponents(url: downloadInfoURL, resolvingAgainstBaseURL: false)
        if components?.queryItems?.contains(where: { $0.name == "format" }) != true {
            if let existing = components?.percentEncodedQuery, !existing.isEmpty {
                components?.percentEncodedQuery = existing + "&format=json"
            } else {
                components?.percentEncodedQuery = "format=json"
            }
        }

        guard let targetURL = components?.url else {
            throw YMAPIError.invalidURL(downloadInfoURL.absoluteString)
        }

        let (data, _) = try await performRawRequest(endpoint: targetURL.absoluteString)
        let decoder = JSONDecoder()

        // downloadInfoUrl response can be wrapped in { result: ... } or raw json
        if let directData = try? decoder.decode(YMStreamData.self, from: data) {
            return directData
        }
        if let envelope = try? decoder.decode(YMResponse<YMStreamData>.self, from: data),
           let result = envelope.result {
            return result
        }
        if let xmlData = parseStorageXML(data: data) {
            return xmlData
        }

        throw YMAPIError.decodingError("Unable to decode YMStreamData from storage endpoint")
    }

    private func parseStorageXML(data: Data) -> YMStreamData? {
        let parser = XMLParser(data: data)
        let delegate = YMStorageXMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse(),
              let host = delegate.host, !host.isEmpty,
              let path = delegate.path, !path.isEmpty,
              let ts = delegate.ts, !ts.isEmpty,
              let s = delegate.s, !s.isEmpty else {
            return nil
        }
        return YMStreamData(host: host, path: path, ts: ts, s: s, region: delegate.region.flatMap(Int.init))
    }

    // MARK: - Direct Audio Stream Resolution Models

    public struct YMFileInfoDownloadInfo: Decodable, Sendable {
        public let url: String?
        public let urls: [String]?
        public let codec: String?
        public let bitrate: Int?
        public let quality: String?
        public let directUrl: String?
        public let key: String?
        public let transport: String?

        enum CodingKeys: String, CodingKey {
            case url
            case urls
            case codec
            case bitrate
            case bitrateInKbps
            case bitRate
            case quality
            case directUrl = "direct-url"
            case key
            case transport
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.url = try? container.decodeIfPresent(String.self, forKey: .url)
            self.urls = try? container.decodeIfPresent([String].self, forKey: .urls)
            self.codec = try? container.decodeIfPresent(String.self, forKey: .codec)
            self.quality = try? container.decodeIfPresent(String.self, forKey: .quality)
            self.directUrl = try? container.decodeIfPresent(String.self, forKey: .directUrl)
            self.key = try? container.decodeIfPresent(String.self, forKey: .key)
            self.transport = try? container.decodeIfPresent(String.self, forKey: .transport)

            if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrate), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrateInKbps), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitRate), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrate), let parsed = Int(bStr), parsed > 0 {
                self.bitrate = parsed > 5000 ? parsed / 1000 : parsed
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrateInKbps), let parsed = Int(bStr), parsed > 0 {
                self.bitrate = parsed > 5000 ? parsed / 1000 : parsed
            } else {
                self.bitrate = nil
            }
        }

        public var effectiveURLString: String? {
            url ?? urls?.first ?? directUrl
        }

        public var isEncrypted: Bool {
            if let key = key, !key.isEmpty { return true }
            if let transport = transport, transport.lowercased().contains("enc") { return true }
            return false
        }
    }

    public struct YMFileInfoPayload: Decodable, Sendable {
        public let downloadInfo: YMFileInfoDownloadInfo?
        public let url: String?
        public let urls: [String]?
        public let codec: String?
        public let bitrate: Int?
        public let quality: String?

        enum CodingKeys: String, CodingKey {
            case downloadInfo
            case url
            case urls
            case codec
            case bitrate
            case bitrateInKbps
            case bitRate
            case quality
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.downloadInfo = try? container.decodeIfPresent(YMFileInfoDownloadInfo.self, forKey: .downloadInfo)
            self.url = try? container.decodeIfPresent(String.self, forKey: .url)
            self.urls = try? container.decodeIfPresent([String].self, forKey: .urls)
            self.codec = try? container.decodeIfPresent(String.self, forKey: .codec)
            self.quality = try? container.decodeIfPresent(String.self, forKey: .quality)

            if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrate), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrateInKbps), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitRate), bInt > 0 {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrate), let parsed = Int(bStr), parsed > 0 {
                self.bitrate = parsed > 5000 ? parsed / 1000 : parsed
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrateInKbps), let parsed = Int(bStr), parsed > 0 {
                self.bitrate = parsed > 5000 ? parsed / 1000 : parsed
            } else {
                self.bitrate = nil
            }
        }
    }

    public struct YMResolvedAudioStream: Sendable {
        public let url: URL
        public let downloadInfo: YMDownloadInfo
        public let allAvailableInfos: [YMDownloadInfo]

        public init(url: URL, downloadInfo: YMDownloadInfo, allAvailableInfos: [YMDownloadInfo]) {
            self.url = url
            self.downloadInfo = downloadInfo
            self.allAvailableInfos = allAvailableInfos
        }
    }

    /// Internal helper requesting direct CDN stream via GET /get-file-info for either Desktop or Android protocol
    private func fetchFileInfoStream(
        trackId: String,
        quality: String = "lossless",
        codecs: String,
        expectedBitrateHint: Int? = nil,
        useDesktopClient: Bool
    ) async -> (info: YMDownloadInfo?, isUnauthorized: Bool) {
        let ts = String(Int(Date().timeIntervalSince1970))
        let cleanTrackId = trackId.components(separatedBy: ":").first ?? trackId
        let secretKey = useDesktopClient ? YMAudioURLSigner.desktopFileInfoSecretKey : YMAudioURLSigner.fileInfoSecretKey
        let sign = YMAudioURLSigner.computeFileInfoSign(
            ts: ts,
            trackId: cleanTrackId,
            quality: quality,
            codecs: codecs,
            transports: "raw",
            secretKey: secretKey
        )

        let queryItems = [
            URLQueryItem(name: "ts", value: ts),
            URLQueryItem(name: "trackId", value: cleanTrackId),
            URLQueryItem(name: "quality", value: quality),
            URLQueryItem(name: "codecs", value: codecs),
            URLQueryItem(name: "transports", value: "raw"),
            URLQueryItem(name: "sign", value: sign)
        ]

        let customHeaders = useDesktopClient ? ["X-Yandex-Music-Client": YMAudioURLSigner.desktopClientHeader] : nil

        do {
            let (data, response) = try await performRawRequest(
                endpoint: "/get-file-info",
                queryItems: queryItems,
                headers: customHeaders,
                cachePolicy: .reloadIgnoringLocalCacheData
            )

            guard (200...299).contains(response.statusCode) else {
                return (nil, false)
            }

            let payload: YMFileInfoPayload?
            if let envelope = try? decoder.decode(YMResponse<YMFileInfoPayload>.self, from: data),
               let res = envelope.result {
                payload = res
            } else {
                payload = try? decoder.decode(YMFileInfoPayload.self, from: data)
            }

            guard let payload = payload else { return (nil, false) }
            if payload.downloadInfo?.isEncrypted == true {
                return (nil, false)
            }

            guard let directUrlStr = payload.downloadInfo?.effectiveURLString ?? payload.url ?? payload.urls?.first,
                  let directURL = URL(string: directUrlStr) else {
                return (nil, false)
            }

            let returnedCodec = (payload.downloadInfo?.codec ?? payload.codec ?? "mp3").lowercased()
            let returnedQuality = (payload.downloadInfo?.quality ?? payload.quality ?? quality).lowercased()
            let isFlacOrAlac = returnedCodec.contains("flac") || returnedCodec.contains("alac")

            let rawBitrate = payload.downloadInfo?.bitrate ?? payload.bitrate
            let resolvedBitrate: Int
            if let b = rawBitrate, b > 0 {
                resolvedBitrate = b
            } else if let hint = expectedBitrateHint {
                resolvedBitrate = hint
            } else if isFlacOrAlac {
                resolvedBitrate = 1000
            } else {
                switch returnedQuality {
                case "lossless", "hq", "high":
                    resolvedBitrate = returnedCodec.contains("mp3") ? 320 : 256
                case "lq", "low":
                    resolvedBitrate = 64
                default:
                    resolvedBitrate = 192
                }
            }

            let isLossless = isFlacOrAlac || resolvedBitrate > 500

            let info = YMDownloadInfo(
                codec: returnedCodec,
                bitrateInKbps: resolvedBitrate,
                downloadInfoUrl: directURL,
                direct: true,
                lossless: isLossless
            )
            return (info, false)
        } catch let apiError as YMAPIError {
            if case .unauthorized = apiError {
                return (nil, true)
            }
            return (nil, false)
        } catch {
            return (nil, false)
        }
    }

    /// Requests direct CDN stream via GET /get-file-info with Desktop protocol, falling back safely to Android protocol
    private func fetchFileInfoStream(
        trackId: String,
        quality: String = "lossless",
        codecs: String,
        expectedBitrateHint: Int? = nil
    ) async -> YMDownloadInfo? {
        let desktopResult = await fetchFileInfoStream(
            trackId: trackId,
            quality: quality,
            codecs: codecs,
            expectedBitrateHint: expectedBitrateHint,
            useDesktopClient: true
        )
        if let info = desktopResult.info {
            return info
        }
        if desktopResult.isUnauthorized {
            return nil
        }
        let fallbackResult = await fetchFileInfoStream(
            trackId: trackId,
            quality: quality,
            codecs: codecs,
            expectedBitrateHint: expectedBitrateHint,
            useDesktopClient: false
        )
        return fallbackResult.info
    }

    /// Resolves direct stream URL taking into account requested quality preset and codec preference.
    /// Gathers all available stream variants (Lossless, HQ 320k, 192k, 128k, 64k) in parallel via async let
    /// and caches availableStreamInfos in memory to avoid redundant queries on preset switches.
    public func resolveAudioStream(
        for trackId: String,
        preset: YMAudioQualityPreset = .high320,
        codecPreference: YMAudioCodecPreference = .any,
        specificInfo: YMDownloadInfo? = nil,
        forceRefresh: Bool = false
    ) async throws -> YMResolvedAudioStream {
        let cleanTrackId = trackId.components(separatedBy: ":").first ?? trackId
        if forceRefresh {
            streamInfosCache.removeValue(forKey: cleanTrackId)
        }

        let allOptions: [YMDownloadInfo]
        var catalogError: Error? = nil

        if !forceRefresh,
           let cached = streamInfosCache[cleanTrackId],
           Date().timeIntervalSince(cached.timestamp) < streamCacheTTL,
           !cached.infos.isEmpty {
            allOptions = cached.infos
        } else {
            async let catalogTask: (infos: [YMDownloadInfo], error: Error?) = {
                do {
                    let catalog = try await getDownloadInfo(for: cleanTrackId)
                    // Оставляем все поддерживаемые потоки каталога (MP3 320/192/128, AAC 192/64), отсеивая только flac
                    let filtered = catalog.filter { !($0.codec.lowercased().contains("flac")) }
                    return (filtered, nil)
                } catch {
                    print("[YMNetworkClient] getDownloadInfo error for \(cleanTrackId): \(error)")
                    return ([], error)
                }
            }()

            // Запрашиваем конкретные кодеки с quality="lossless" — это стандартный способ получить от /get-file-info
            // максимальный поток для каждого кодека (FLAC, MP3 320k, AAC, HE-AAC) без ошибок валидации подписи.
            async let flacTask = fetchFileInfoStream(trackId: cleanTrackId, quality: "lossless", codecs: "flac,flac-mp4", expectedBitrateHint: 1000)
            async let mp3HqTask = fetchFileInfoStream(trackId: cleanTrackId, quality: "lossless", codecs: "mp3", expectedBitrateHint: 320)
            async let aacHqTask = fetchFileInfoStream(trackId: cleanTrackId, quality: "lossless", codecs: "aac,aac-mp4", expectedBitrateHint: 256)
            async let heAacTask = fetchFileInfoStream(trackId: cleanTrackId, quality: "lossless", codecs: "he-aac,he-aac-mp4", expectedBitrateHint: 64)

            let (catalogResult, flacInfo, mp3HqInfo, aacHqInfo, heAacInfo) = await (
                catalogTask,
                flacTask,
                mp3HqTask,
                aacHqTask,
                heAacTask
            )

            let catalogInfos = catalogResult.infos
            catalogError = catalogResult.error

            var candidates: [YMDownloadInfo] = []
            // 1. Сначала добавляем прямые потоки из /get-file-info (FLAC, MP3 320, AAC, HE-AAC)
            if let flac = flacInfo { candidates.append(flac) }
            if let mp3Hq = mp3HqInfo { candidates.append(mp3Hq) }
            if let aacHq = aacHqInfo { candidates.append(aacHq) }
            if let heAac = heAacInfo { candidates.append(heAac) }

            // 2. Затем добавляем все потоки из каталога /download-info (MP3 320/192/128, AAC 192/64)
            candidates.append(contentsOf: catalogInfos)

            var dedupMap: [String: YMDownloadInfo] = [:]
            var uniqueURLs = Set<String>()

            for stream in candidates {
                if stream.isDirectCdnStream {
                    if uniqueURLs.contains(stream.downloadInfoUrl.absoluteString) {
                        continue
                    }
                    uniqueURLs.insert(stream.downloadInfoUrl.absoluteString)
                }

                let key = "\(stream.codec.lowercased())_\(stream.bitrateInKbps)"
                if let existing = dedupMap[key] {
                    // Предпочитаем прямой CDN-поток каталожному при одинаковом кодеке и битрейте
                    if !existing.isDirectCdnStream && stream.isDirectCdnStream {
                        dedupMap[key] = stream
                    }
                } else {
                    dedupMap[key] = stream
                }
            }

            let sortedOptions = Array(dedupMap.values).sorted { a, b in
                if a.isLossless != b.isLossless {
                    return a.isLossless && !b.isLossless
                }
                if a.bitrateInKbps != b.bitrateInKbps {
                    return a.bitrateInKbps > b.bitrateInKbps
                }
                return a.codec.lowercased().contains("mp3") && !b.codec.lowercased().contains("mp3")
            }

            allOptions = sortedOptions

            if streamInfosCache.count > 100 {
                let now = Date()
                streamInfosCache = streamInfosCache.filter { now.timeIntervalSince($0.value.timestamp) < streamCacheTTL }
                if streamInfosCache.count > 100 {
                    streamInfosCache.removeAll()
                }
            }
            if !sortedOptions.isEmpty {
                streamInfosCache[cleanTrackId] = CachedStreamInfos(timestamp: Date(), infos: sortedOptions)
            }
        }

        let selected: YMDownloadInfo
        if let specific = specificInfo,
           let found = allOptions.first(where: { $0.matchesVariant(specific) }) {
            selected = found
        } else if let specific = specificInfo {
            if specific.isDirectCdnStream && !forceRefresh {
                return try await resolveAudioStream(
                    for: trackId,
                    preset: preset,
                    codecPreference: codecPreference,
                    specificInfo: specificInfo,
                    forceRefresh: true
                )
            }
            selected = specific
        } else if let matched = allOptions.selectDownloadInfo(preset: preset, codecPreference: codecPreference) {
            selected = matched
        } else if let fallback = allOptions.selectBestAudioDownloadInfo() {
            selected = fallback
        } else {
            if let catalogError = catalogError as? YMAPIError, case .unauthorized = catalogError {
                throw YMAPIError.unauthorized
            }
            throw YMAPIError.decodingError("No suitable audio download stream found for track \(trackId)")
        }

        let finalURL: URL
        if selected.isDirectCdnStream {
            finalURL = selected.downloadInfoUrl
        } else {
            let streamData = try await fetchStreamData(from: selected.downloadInfoUrl)
            guard let signedURL = YMAudioURLSigner.signStream(from: streamData) else {
                throw YMAPIError.decodingError("Failed to calculate signed audio stream URL")
            }
            finalURL = signedURL
        }

        return YMResolvedAudioStream(url: finalURL, downloadInfo: selected, allAvailableInfos: allOptions)
    }

    /// Complete 2-step direct stream resolution with MD5 signing (convenience overload)
    public func resolveAudioStreamURL(for trackId: String) async throws -> URL {
        let stream = try await resolveAudioStream(for: trackId)
        return stream.url
    }

    // MARK: - Cache Management

    public func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
        streamInfosCache.removeAll()
        lyricsLRCCache.removeAll()
        lyricsLRCCacheOrder.removeAll()
    }

    // MARK: - Account Status Verification

    public func getAccountStatus() async throws -> YMAccountStatus {
        try await request(endpoint: "/account/status")
    }

    // MARK: - Full Track Batch Fetching

    /// POST /tracks with body "track-ids=id1,id2,..." chunked into batches of 50
    public func fetchTracks(trackIds: [String]) async throws -> [YMTrack] {
        guard !trackIds.isEmpty else { return [] }
        let chunkSize = 50
        var allTracks: [YMTrack] = []
        var lastError: Error?

        for chunkStart in stride(from: 0, to: trackIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, trackIds.count)
            let chunk = Array(trackIds[chunkStart..<chunkEnd])
            let bodyData = Self.formEncodedBody([("track-ids", chunk.joined(separator: ","))])

            do {
                let chunkTracks: [YMTrack] = try await request(
                    endpoint: "/tracks",
                    method: "POST",
                    body: bodyData,
                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                    cachePolicy: .reloadIgnoringLocalCacheData
                )
                allTracks.append(contentsOf: chunkTracks)
            } catch {
                lastError = error
                print("[YMNetworkClient] Error fetching track chunk [\(chunkStart)..<\(chunkEnd)]: \(error)")
            }
        }

        if allTracks.isEmpty, let error = lastError {
            throw error
        }

        return allTracks
    }

    // MARK: - Playlists API

    private static func formEncodedBody(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = pairs.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    /// GET /users/{uid}/playlists/list
    public func fetchUserPlaylists(
        uid: String,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
    ) async throws -> [YMPlaylist] {
        try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/list",
            cachePolicy: cachePolicy
        )
    }

    /// GET /users/{uid}/playlists/{kind}
    public func fetchPlaylistDetails(
        uid: String,
        kind: Int,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData
    ) async throws -> YMPlaylist {
        try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)",
            cachePolicy: cachePolicy
        )
    }

    /// POST /users/{uid}/playlists/create
    /// Creates a new playlist with title, visibility ("public" or "private"), and optional description.
    public func createPlaylist(
        uid: String,
        title: String,
        description: String? = nil,
        visibility: String = "public"
    ) async throws -> YMPlaylist {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVisibility = (visibility.lowercased() == "private") ? "private" : "public"
        var formPairs: [(String, String)] = [
            ("title", trimmedTitle),
            ("visibility", normalizedVisibility)
        ]
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let desc = trimmedDescription, !desc.isEmpty {
            formPairs.append(("description", desc))
        }

        var created: YMPlaylist = try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/create",
            method: "POST",
            body: Self.formEncodedBody(formPairs),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            cachePolicy: .reloadIgnoringLocalCacheData
        )

        // Yandex Music's /create endpoint sometimes ignores description in the initial form;
        // persist it via the dedicated description endpoint if not echoed back.
        if let desc = trimmedDescription, !desc.isEmpty, (created.description ?? "").isEmpty {
            if let updated = try? await updatePlaylistDescription(uid: uid, kind: created.kind, description: desc) {
                created = updated
            }
        }
        return created
    }

    /// POST /users/{uid}/playlists/{kind}/name
    public func updatePlaylistName(uid: String, kind: Int, title: String) async throws -> YMPlaylist {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/name",
            method: "POST",
            body: Self.formEncodedBody([("value", trimmedTitle)]),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// POST /users/{uid}/playlists/{kind}/description
    public func updatePlaylistDescription(uid: String, kind: Int, description: String) async throws -> YMPlaylist {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/description",
            method: "POST",
            body: Self.formEncodedBody([("value", trimmed)]),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// POST /users/{uid}/playlists/{kind}/visibility
    public func updatePlaylistVisibility(uid: String, kind: Int, visibility: String) async throws -> YMPlaylist {
        let normalizedVisibility = (visibility.lowercased() == "private") ? "private" : "public"
        return try await request(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/visibility",
            method: "POST",
            body: Self.formEncodedBody([("value", normalizedVisibility)]),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// POST /users/{uid}/playlists/{kind}/delete
    public func deletePlaylist(uid: String, kind: Int) async throws {
        let (data, response) = try await performRawRequest(
            endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/delete",
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        guard (200...299).contains(response.statusCode) else {
            throw YMAPIError.httpError(statusCode: response.statusCode, data: data)
        }
        if let env = try? decoder.decode(YMResponse<String>.self, from: data), env.error != nil {
            _ = try env.unwrap()
        }
    }

    /// POST /users/{uid}/playlists/{kind}/change-relative (insert tracks)
    public func addTracksToPlaylist(
        uid: String,
        kind: Int,
        revision: Int,
        tracks: [YMTrack],
        at index: Int = 0
    ) async throws -> YMPlaylist {
        struct DiffTrack: Encodable {
            let id: String
            let albumId: String?
        }
        struct InsertDiff: Encodable {
            let op: String
            let at: Int
            let tracks: [DiffTrack]
        }

        let diffTracks = tracks.map { track -> DiffTrack in
            let parts = track.id.split(separator: ":", maxSplits: 1).map(String.init)
            let cleanId = parts.first ?? track.id
            let albumId = track.albums.first?.id ?? (parts.count > 1 ? parts[1] : nil)
            return DiffTrack(id: cleanId, albumId: albumId)
        }
        let diffPayload = [InsertDiff(op: "insert", at: max(0, index), tracks: diffTracks)]
        let diffData = try encoder.encode(diffPayload)
        let diffJSON = String(data: diffData, encoding: .utf8) ?? "[]"

        do {
            return try await request(
                endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/change-relative",
                method: "POST",
                body: Self.formEncodedBody([
                    ("kind", String(kind)),
                    ("diff", diffJSON),
                    ("revision", String(revision))
                ]),
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } catch let YMAPIError.httpError(statusCode, _) where statusCode == 404 || statusCode == 405 {
            return try await request(
                endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/change",
                method: "POST",
                body: Self.formEncodedBody([
                    ("kind", String(kind)),
                    ("diff", diffJSON),
                    ("revision", String(revision))
                ]),
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        }
    }

    /// POST /users/{uid}/playlists/{kind}/change-relative (delete track at index)
    public func removeTrackFromPlaylist(
        uid: String,
        kind: Int,
        revision: Int,
        at index: Int
    ) async throws -> YMPlaylist {
        guard index >= 0 else {
            throw YMAPIError.serverError(name: "invalid-index", message: "Invalid track index")
        }

        struct DeleteDiff: Encodable {
            let op: String
            let from: Int
            let to: Int
        }
        let diffPayload = [DeleteDiff(op: "delete", from: index, to: index + 1)]
        let diffData = try encoder.encode(diffPayload)
        let diffJSON = String(data: diffData, encoding: .utf8) ?? "[]"

        do {
            return try await request(
                endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/change-relative",
                method: "POST",
                body: Self.formEncodedBody([
                    ("kind", String(kind)),
                    ("diff", diffJSON),
                    ("revision", String(revision))
                ]),
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } catch let YMAPIError.httpError(statusCode, _) where statusCode == 404 || statusCode == 405 {
            return try await request(
                endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)/change",
                method: "POST",
                body: Self.formEncodedBody([
                    ("kind", String(kind)),
                    ("diff", diffJSON),
                    ("revision", String(revision))
                ]),
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        }
    }

    // MARK: - Search & Artist API

    /// GET /artists/{artistId}/tracks?page={page}&page-size={pageSize}
    public func fetchArtistTracks(artistId: String, page: Int = 0, pageSize: Int = 20) async throws -> [YMTrack] {
        let queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page-size", value: String(pageSize))
        ]
        let response: YMArtistTracksResponse = try await request(endpoint: "/artists/\(Self.escapePath(artistId))/tracks", queryItems: queryItems)
        return response.tracks
    }

    /// GET /artists/{artistId}/brief-info
    public func fetchArtistBriefInfo(artistId: String) async throws -> YMArtistBriefInfo {
        try await request(endpoint: "/artists/\(Self.escapePath(artistId))/brief-info")
    }

    /// GET /albums/{albumId}/with-tracks
    public func fetchAlbumWithTracks(albumId: String) async throws -> YMAlbumWithTracks {
        try await request(endpoint: "/albums/\(Self.escapePath(albumId))/with-tracks")
    }

    /// GET /landing3/chart
    public func fetchChart() async throws -> [YMChartItem] {
        let response: YMChartResponse = try await request(endpoint: "/landing3/chart")
        return response.chart?.tracks ?? []
    }

    /// GET /tracks/{trackId}/supplement
    public func fetchTrackSupplement(trackId: String) async throws -> YMTrackSupplement {
        let numericId = OfflineTrackID.clean(trackId)
        do {
            return try await request(endpoint: "/tracks/\(Self.escapePath(trackId))/supplement")
        } catch {
            if let plain = await OfflineStorageStore.shared.loadLyrics(for: numericId)?.plain,
               !plain.isEmpty {
                return YMTrackSupplement(id: numericId, lyrics: YMLyrics(lyrics: plain, fullLyrics: plain))
            }
            throw error
        }
    }

    /// Response envelope for GET /tracks/{trackId}/lyrics
    public struct YMLyricsEnvelope: Decodable, Sendable {
        public let downloadUrl: String?
        public let lyricId: Int?
        public let externalLyricId: String?

        enum CodingKeys: String, CodingKey {
            case downloadUrl
            case downloadUrlSnake = "download_url"
            case downloadUrlKebab = "download-url"
            case lyricId
            case lyricIdSnake = "lyric_id"
            case externalLyricId
            case externalLyricIdSnake = "external_lyric_id"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.downloadUrl = (try? container.decodeIfPresent(String.self, forKey: .downloadUrl))
                ?? (try? container.decodeIfPresent(String.self, forKey: .downloadUrlSnake))
                ?? (try? container.decodeIfPresent(String.self, forKey: .downloadUrlKebab))
            self.lyricId = (try? container.decodeIfPresent(Int.self, forKey: .lyricId))
                ?? (try? container.decodeIfPresent(Int.self, forKey: .lyricIdSnake))
            self.externalLyricId = (try? container.decodeIfPresent(String.self, forKey: .externalLyricId))
                ?? (try? container.decodeIfPresent(String.self, forKey: .externalLyricIdSnake))
        }
    }

    /// Downloads raw LRC text for a track using HMAC-SHA256 signed endpoint.
    public func fetchTrackLyricsRawLRC(trackId: String) async throws -> String? {
        let numericId = OfflineTrackID.clean(trackId)
        let timestamp = Int(Date().timeIntervalSince1970)
        let sign = YMAudioURLSigner.computeLyricsSign(trackId: numericId, timestamp: timestamp)

        let queryItems = [
            URLQueryItem(name: "format", value: "LRC"),
            URLQueryItem(name: "timeStamp", value: String(timestamp)),
            URLQueryItem(name: "sign", value: sign)
        ]

        let envelope: YMLyricsEnvelope
        do {
            envelope = try await request(
                endpoint: "/tracks/\(Self.escapePath(numericId))/lyrics",
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )
        } catch {
            return nil
        }

        guard var downloadUrl = envelope.downloadUrl, !downloadUrl.isEmpty else {
            return nil
        }
        if downloadUrl.hasPrefix("http://") {
            downloadUrl = "https://" + downloadUrl.dropFirst("http://".count)
        }
        guard let s3URL = URL(string: downloadUrl) else {
            return nil
        }

        // Direct request to S3 without OAuth header to avoid S3 authentication signature mismatch
        var s3Request = URLRequest(url: s3URL)
        s3Request.cachePolicy = .useProtocolCachePolicy
        s3Request.timeoutInterval = 15
        let (data, response) = try await session.data(for: s3Request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let lrcContent = String(data: data, encoding: .utf8) else {
            return nil
        }

        return lrcContent
    }

    private func cacheSyncedLyrics(_ lrcContent: String, for numericId: String) -> YMSyncedLyrics? {
        let synced = YMSyncedLyrics.parse(lrcContent: lrcContent)
        guard !synced.isEmpty else { return nil }
        lyricsLRCCache[numericId] = synced
        lyricsLRCCacheOrder.removeAll { $0 == numericId }
        lyricsLRCCacheOrder.append(numericId)
        while lyricsLRCCacheOrder.count > 12 {
            let evicted = lyricsLRCCacheOrder.removeFirst()
            lyricsLRCCache.removeValue(forKey: evicted)
        }
        return synced
    }

    /// Fetches time-synchronized LRC lyrics for a track, checking in-memory cache and encrypted offline lyrics first.
    /// Returns nil if synchronized lyrics are not available for this track.
    public func fetchTrackLyricsLRC(trackId: String) async throws -> YMSyncedLyrics? {
        let numericId = OfflineTrackID.clean(trackId)
        if let cached = lyricsLRCCache[numericId] {
            return cached
        }

        if let offlineLRC = await OfflineStorageStore.shared.loadLyrics(for: numericId)?.lrc,
           let parsed = cacheSyncedLyrics(offlineLRC, for: numericId) {
            return parsed
        }

        if let rawLRC = try await fetchTrackLyricsRawLRC(trackId: numericId),
           let parsed = cacheSyncedLyrics(rawLRC, for: numericId) {
            return parsed
        }

        return nil
    }

    /// GET /tracks/{trackId}/similar
    public func fetchSimilarTracks(trackId: String) async throws -> [YMTrack] {
        struct SimilarResponse: Codable, Sendable {
            let similarTracks: [YMTrack]
            enum CodingKeys: String, CodingKey {
                case similarTracks
            }
        }
        let response: SimilarResponse = try await request(endpoint: "/tracks/\(Self.escapePath(trackId))/similar")
        return response.similarTracks
    }

    /// Internal helper performing unified search for page 0 once to eliminate duplicate network requests
    private func fetchSearchAllPageZero(trimmed: String) async throws -> (response: YMSearchResponse, tracks: [YMTrack]) {
        let queryItems = [
            URLQueryItem(name: "text", value: trimmed),
            URLQueryItem(name: "type", value: "all"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "nocorrect", value: "false")
        ]

        let response: YMSearchResponse = try await request(endpoint: "/search", queryItems: queryItems)
        let directTracks = response.tracks?.results ?? []

        // Check if best match is an artist or if top artist closely matches query
        var matchingArtistId: String? = nil
        if response.best?.type == "artist", let artistId = response.best?.result?.id {
            matchingArtistId = artistId
        } else if let firstArtist = response.artists?.results.first {
            let artistName = firstArtist.name.lowercased()
            let q = trimmed.lowercased()
            if artistName == q || artistName.contains(q) || q.contains(artistName) {
                matchingArtistId = firstArtist.id
            }
        }

        if let artistId = matchingArtistId {
            // Fetch top tracks for matching artist
            let artistTracks = (try? await fetchArtistTracks(artistId: artistId, page: 0, pageSize: 20)) ?? []
            if !artistTracks.isEmpty {
                var combined: [YMTrack] = []
                var seenIds = Set<String>()
                // Prepend artist's top tracks
                for t in artistTracks {
                    if !seenIds.contains(t.id) {
                        seenIds.insert(t.id)
                        combined.append(t)
                    }
                }
                // Append direct matching tracks
                for t in directTracks {
                    if !seenIds.contains(t.id) {
                        seenIds.insert(t.id)
                        combined.append(t)
                    }
                }
                return (response, combined)
            }
        }

        return (response, directTracks)
    }

    /// Comprehensive unified search returning tracks, artists, and albums:
    /// GET /search?text={query}&type=all&page={page}&nocorrect=false
    public func searchAll(query: String, page: Int = 0) async throws -> YMFullSearchResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return YMFullSearchResult(tracks: [], artists: [], albums: [])
        }

        if page == 0 {
            let (response, tracks) = try await fetchSearchAllPageZero(trimmed: trimmed)
            var directAlbums = response.albums?.results ?? []
            var directArtists = response.artists?.results ?? []

            // Extract unique albums from tracks if directAlbums has few/none
            var seenAlbumIds = Set(directAlbums.map(\.id))
            for track in tracks {
                if let album = track.albums.first, !seenAlbumIds.contains(album.id) {
                    seenAlbumIds.insert(album.id)
                    directAlbums.append(album)
                }
            }

            // Extract unique artists from tracks if directArtists has few/none
            var seenArtistIds = Set(directArtists.map(\.id))
            for track in tracks {
                for artist in track.artists {
                    if !seenArtistIds.contains(artist.id) {
                        seenArtistIds.insert(artist.id)
                        directArtists.append(artist)
                    }
                }
            }

            return YMFullSearchResult(
                tracks: tracks,
                artists: Array(directArtists.prefix(16)),
                albums: Array(directAlbums.prefix(16))
            )
        } else {
            let tracks = try await searchTracks(query: trimmed, page: page)
            return YMFullSearchResult(tracks: tracks, artists: [], albums: [])
        }
    }

    /// Global search with intelligent artist resolution and track discovery:
    /// GET /search?text={query}&type=all&page={page}&nocorrect=false
    public func searchTracks(query: String, page: Int = 0) async throws -> [YMTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if page == 0 {
            let (_, tracks) = try await fetchSearchAllPageZero(trimmed: trimmed)
            return tracks
        } else {
            // Subsequent pages paginate through tracks
            let queryItems = [
                URLQueryItem(name: "text", value: trimmed),
                URLQueryItem(name: "type", value: "track"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "nocorrect", value: "false")
            ]
            let response: YMSearchResponse = try await request(endpoint: "/search", queryItems: queryItems)
            return response.tracks?.results ?? []
        }
    }
}

// MARK: - XML Parser Delegate for Audio Storage Responses

private final class YMStorageXMLParserDelegate: NSObject, XMLParserDelegate, @unchecked Sendable {
    var host: String?
    var path: String?
    var ts: String?
    var s: String?
    var region: String?

    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "host": host = trimmed
        case "path": path = trimmed
        case "ts": ts = trimmed
        case "s": s = trimmed
        case "region": region = trimmed
        default: break
        }
    }
}
