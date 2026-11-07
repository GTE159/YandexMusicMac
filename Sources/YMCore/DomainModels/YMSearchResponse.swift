import Foundation

public struct YMSearchResponse: Codable, Sendable {
    public let type: String?
    public let page: Int?
    public let total: Int?
    public let perPage: Int?
    public let text: String?
    public let tracks: YMSearchTracksBlock?
    public let best: YMSearchBestBlock?
    public let artists: YMSearchArtistsBlock?
    public let albums: YMSearchAlbumsBlock?

    public init(
        type: String? = nil,
        page: Int? = nil,
        total: Int? = nil,
        perPage: Int? = nil,
        text: String? = nil,
        tracks: YMSearchTracksBlock? = nil,
        best: YMSearchBestBlock? = nil,
        artists: YMSearchArtistsBlock? = nil,
        albums: YMSearchAlbumsBlock? = nil
    ) {
        self.type = type
        self.page = page
        self.total = total
        self.perPage = perPage
        self.text = text
        self.tracks = tracks
        self.best = best
        self.artists = artists
        self.albums = albums
    }
}

public struct YMSearchAlbumsBlock: Codable, Sendable {
    public let total: Int?
    public let results: [YMAlbum]

    enum CodingKeys: String, CodingKey {
        case total
        case results
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try? container.decodeIfPresent(Int.self, forKey: .total)
        self.results = (try? container.decodeIfPresent([YMAlbum].self, forKey: .results)) ?? []
    }

    public init(total: Int? = nil, results: [YMAlbum] = []) {
        self.total = total
        self.results = results
    }
}

public struct YMFullSearchResult: Sendable {
    public let tracks: [YMTrack]
    public let artists: [YMArtist]
    public let albums: [YMAlbum]

    public init(tracks: [YMTrack] = [], artists: [YMArtist] = [], albums: [YMAlbum] = []) {
        self.tracks = tracks
        self.artists = artists
        self.albums = albums
    }
}

public struct YMSearchBestBlock: Codable, Sendable {
    public let type: String?
    public let result: YMSearchBestResult?

    public init(type: String? = nil, result: YMSearchBestResult? = nil) {
        self.type = type
        self.result = result
    }
}

public struct YMSearchBestResult: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = FlexibleIDDecoder.decodeStringIfPresent(from: container, forKey: .id)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.title = try? container.decodeIfPresent(String.self, forKey: .title)
    }

    public init(id: String? = nil, name: String? = nil, title: String? = nil) {
        self.id = id
        self.name = name
        self.title = title
    }
}

public struct YMSearchArtistsBlock: Codable, Sendable {
    public let total: Int?
    public let results: [YMArtist]

    enum CodingKeys: String, CodingKey {
        case total
        case results
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try? container.decodeIfPresent(Int.self, forKey: .total)
        self.results = (try? container.decodeIfPresent([YMArtist].self, forKey: .results)) ?? []
    }

    public init(total: Int? = nil, results: [YMArtist] = []) {
        self.total = total
        self.results = results
    }
}

public struct YMSearchTracksBlock: Codable, Sendable {
    public let total: Int?
    public let perPage: Int?
    public let order: Int?
    public let results: [YMTrack]

    enum CodingKeys: String, CodingKey {
        case total
        case perPage
        case order
        case results
    }

    public init(total: Int? = nil, perPage: Int? = nil, order: Int? = nil, results: [YMTrack] = []) {
        self.total = total
        self.perPage = perPage
        self.order = order
        self.results = results
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.total = try? container.decodeIfPresent(Int.self, forKey: .total)
        self.perPage = try? container.decodeIfPresent(Int.self, forKey: .perPage)
        self.order = try? container.decodeIfPresent(Int.self, forKey: .order)

        if let tracks = try? container.decodeIfPresent([YMTrack].self, forKey: .results) {
            self.results = tracks
        } else if var arrContainer = try? container.nestedUnkeyedContainer(forKey: .results) {
            var validTracks: [YMTrack] = []
            while !arrContainer.isAtEnd {
                if let track = try? arrContainer.decode(YMTrack.self) {
                    validTracks.append(track)
                } else {
                    _ = try? arrContainer.decode(DummyTrackSkipper.self)
                }
            }
            self.results = validTracks
        } else {
            self.results = []
        }
    }
}

public struct YMArtistTracksResponse: Codable, Sendable {
    public let tracks: [YMTrack]

    enum CodingKeys: String, CodingKey {
        case tracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tracks = (try? container.decodeIfPresent([YMTrack].self, forKey: .tracks)) ?? []
    }

    public init(tracks: [YMTrack] = []) {
        self.tracks = tracks
    }
}

private struct DummyTrackSkipper: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.container(keyedBy: DynamicCodingKey.self)
        _ = try? decoder.singleValueContainer()
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int?
        init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
    }
}
