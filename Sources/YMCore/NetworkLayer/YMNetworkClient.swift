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
    private let streamCacheTTL: TimeInterval = 600 // 10 минут

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

            // Percent-encode query item values properly, especially ensuring '+' is encoded as '%2B',
            // '/' as '%2F', and ',' as '%2C' (RFC 3986 unreserved: alphanumerics and "-._~").
            var queryParts: [String] = []
            for item in existingItems {
                let name = item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.name
                let value = item.value?.addingPercentEncoding(
                    withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                ) ?? ""
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
        try await request(endpoint: "/tracks/\(Self.escapePath(trackId))/download-info")
    }

    /// Step 2: GET {downloadInfoUrl}&format=json -> Parse host, path, ts, s
    public func fetchStreamData(from downloadInfoURL: URL) async throws -> YMStreamData {
        var components = URLComponents(url: downloadInfoURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: "format", value: "json"))
        components?.queryItems = queryItems

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

        throw YMAPIError.decodingError("Unable to decode YMStreamData from storage endpoint")
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

            if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrate) {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitrateInKbps) {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bInt = try? container.decodeIfPresent(Int.self, forKey: .bitRate) {
                self.bitrate = bInt > 5000 ? bInt / 1000 : bInt
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrate), let parsed = Int(bStr) {
                self.bitrate = parsed > 5000 ? parsed / 1000 : parsed
            } else if let bStr = try? container.decodeIfPresent(String.self, forKey: .bitrateInKbps), let parsed = Int(bStr) {
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

    /// Requests direct CDN stream via GET /get-file-info with signature validation
    private func fetchFileInfoStream(
        trackId: String,
        quality: String = "lossless",
        codecs: String,
        expectedBitrateHint: Int? = nil
    ) async -> YMDownloadInfo? {
        let ts = String(Int(Date().timeIntervalSince1970))
        let cleanTrackId = trackId.components(separatedBy: ":").first ?? trackId
        let sign = YMAudioURLSigner.computeFileInfoSign(
            ts: ts,
            trackId: cleanTrackId,
            quality: quality,
            codecs: codecs,
            transports: "raw"
        )

        let queryItems = [
            URLQueryItem(name: "ts", value: ts),
            URLQueryItem(name: "trackId", value: cleanTrackId),
            URLQueryItem(name: "quality", value: quality),
            URLQueryItem(name: "codecs", value: codecs),
            URLQueryItem(name: "transports", value: "raw"),
            URLQueryItem(name: "sign", value: sign)
        ]

        do {
            let (data, response) = try await performRawRequest(
                endpoint: "/get-file-info",
                queryItems: queryItems,
                cachePolicy: .reloadIgnoringLocalCacheData
            )

            guard (200...299).contains(response.statusCode) else {
                return nil
            }

            let payload: YMFileInfoPayload?
            if let envelope = try? decoder.decode(YMResponse<YMFileInfoPayload>.self, from: data),
               let res = envelope.result {
                payload = res
            } else {
                payload = try? decoder.decode(YMFileInfoPayload.self, from: data)
            }

            guard let payload = payload else { return nil }
            if payload.downloadInfo?.isEncrypted == true {
                return nil
            }

            guard let directUrlStr = payload.downloadInfo?.effectiveURLString ?? payload.url ?? payload.urls?.first,
                  let directURL = URL(string: directUrlStr) else {
                return nil
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

            return YMDownloadInfo(
                codec: returnedCodec,
                bitrateInKbps: resolvedBitrate,
                downloadInfoUrl: directURL,
                direct: true,
                lossless: isLossless
            )
        } catch {
            return nil
        }
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
        if forceRefresh {
            streamInfosCache.removeValue(forKey: trackId)
        }

        let allOptions: [YMDownloadInfo]

        if !forceRefresh,
           let cached = streamInfosCache[trackId],
           Date().timeIntervalSince(cached.timestamp) < streamCacheTTL,
           !cached.infos.isEmpty {
            allOptions = cached.infos
        } else {
            async let catalogTask: [YMDownloadInfo] = {
                do {
                    let catalog = try await getDownloadInfo(for: trackId)
                    // Оставляем все поддерживаемые потоки каталога (MP3 320/192/128, AAC 192/64), отсеивая только flac
                    return catalog.filter { !($0.codec.lowercased().contains("flac")) }
                } catch {
                    print("[YMNetworkClient] getDownloadInfo error for \(trackId): \(error)")
                    return []
                }
            }()

            // Запрашиваем конкретные кодеки с quality="lossless" — это стандартный способ получить от /get-file-info
            // максимальный поток для каждого кодека (FLAC, MP3 320k, AAC, HE-AAC) без ошибок валидации подписи.
            async let flacTask = fetchFileInfoStream(trackId: trackId, quality: "lossless", codecs: "flac,flac-mp4", expectedBitrateHint: 1000)
            async let mp3HqTask = fetchFileInfoStream(trackId: trackId, quality: "lossless", codecs: "mp3", expectedBitrateHint: 320)
            async let aacHqTask = fetchFileInfoStream(trackId: trackId, quality: "lossless", codecs: "aac,aac-mp4", expectedBitrateHint: 256)
            async let heAacTask = fetchFileInfoStream(trackId: trackId, quality: "lossless", codecs: "he-aac,he-aac-mp4", expectedBitrateHint: 64)

            let (catalogInfos, flacInfo, mp3HqInfo, aacHqInfo, heAacInfo) = await (
                catalogTask,
                flacTask,
                mp3HqTask,
                aacHqTask,
                heAacTask
            )

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
                streamInfosCache[trackId] = CachedStreamInfos(timestamp: Date(), infos: sortedOptions)
            }
        }

        let selected: YMDownloadInfo
        if let specific = specificInfo,
           let found = allOptions.first(where: { $0.matchesVariant(specific) }) {
            selected = found
        } else if let specific = specificInfo {
            selected = specific
        } else if let matched = allOptions.selectDownloadInfo(preset: preset, codecPreference: codecPreference) {
            selected = matched
        } else if let fallback = allOptions.selectBestAudioDownloadInfo() {
            selected = fallback
        } else {
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

        for chunkStart in stride(from: 0, to: trackIds.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, trackIds.count)
            let chunk = Array(trackIds[chunkStart..<chunkEnd])
            let bodyString = "track-ids=" + chunk.joined(separator: ",")
            guard let bodyData = bodyString.data(using: .utf8) else { continue }

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
                print("[YMNetworkClient] Error fetching track chunk [\(chunkStart)..<\(chunkEnd)]: \(error)")
            }
        }

        return allTracks
    }

    // MARK: - Playlists API

    /// GET /users/{uid}/playlists/list
    public func fetchUserPlaylists(uid: String) async throws -> [YMPlaylist] {
        try await request(endpoint: "/users/\(Self.escapePath(uid))/playlists/list")
    }

    /// GET /users/{uid}/playlists/{kind}
    public func fetchPlaylistDetails(uid: String, kind: Int) async throws -> YMPlaylist {
        try await request(endpoint: "/users/\(Self.escapePath(uid))/playlists/\(kind)")
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
        try await request(endpoint: "/tracks/\(Self.escapePath(trackId))/supplement")
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

    /// Fetches time-synchronized LRC lyrics for a track, signed with HMAC-SHA256.
    /// Returns nil if synchronized lyrics are not available for this track.
    public func fetchTrackLyricsLRC(trackId: String) async throws -> YMSyncedLyrics? {
        let numericId = trackId.components(separatedBy: ":").first ?? trackId
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
                queryItems: queryItems
            )
        } catch {
            return nil
        }

        guard let downloadUrl = envelope.downloadUrl, !downloadUrl.isEmpty,
              let s3URL = URL(string: downloadUrl) else {
            return nil
        }

        // Direct request to S3 without OAuth header to avoid S3 authentication signature mismatch
        var s3Request = URLRequest(url: s3URL)
        s3Request.cachePolicy = .useProtocolCachePolicy
        s3Request.timeoutInterval = 15
        let (data, response) = try await session.data(for: s3Request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let lrcContent = String(data: data, encoding: .utf8) else {
            return nil
        }

        let synced = YMSyncedLyrics.parse(lrcContent: lrcContent)
        return synced.isEmpty ? nil : synced
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

    /// Global search with intelligent artist resolution and track discovery:
    /// GET /search?text={query}&type=all&page={page}&nocorrect=false
    public func searchTracks(query: String, page: Int = 0) async throws -> [YMTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if page == 0 {
            // First page uses type=all to discover both matching tracks and artist matches
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
                    return combined
                }
            }

            return directTracks
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
