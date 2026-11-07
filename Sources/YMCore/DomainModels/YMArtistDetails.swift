import Foundation

/// Detailed artist information returned by `GET /artists/{artistId}/brief-info`.
public struct YMArtistBriefInfo: Codable, Sendable {
    public let artist: YMArtist
    public let albums: [YMAlbum]
    public let alsoAlbums: [YMAlbum]
    public let popularTracks: [YMTrack]
    public let similarArtists: [YMArtist]
    public let stats: YMArtistStats?
    public let counts: YMArtistCounts?
    public let description: YMArtistDescription?

    enum CodingKeys: String, CodingKey {
        case artist
        case albums
        case alsoAlbums
        case popularTracks
        case similarArtists
        case stats
        case counts
        case description
    }

    public init(
        artist: YMArtist,
        albums: [YMAlbum] = [],
        alsoAlbums: [YMAlbum] = [],
        popularTracks: [YMTrack] = [],
        similarArtists: [YMArtist] = [],
        stats: YMArtistStats? = nil,
        counts: YMArtistCounts? = nil,
        description: YMArtistDescription? = nil
    ) {
        self.artist = artist
        self.albums = albums
        self.alsoAlbums = alsoAlbums
        self.popularTracks = popularTracks
        self.similarArtists = similarArtists
        self.stats = stats
        self.counts = counts
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.artist = try container.decode(YMArtist.self, forKey: .artist)
        self.albums = (try? container.decodeIfPresent([YMAlbum].self, forKey: .albums)) ?? []
        self.alsoAlbums = (try? container.decodeIfPresent([YMAlbum].self, forKey: .alsoAlbums)) ?? []
        self.popularTracks = (try? container.decodeIfPresent([YMTrack].self, forKey: .popularTracks)) ?? []
        self.similarArtists = (try? container.decodeIfPresent([YMArtist].self, forKey: .similarArtists)) ?? []
        self.stats = try? container.decodeIfPresent(YMArtistStats.self, forKey: .stats)
        self.counts = try? container.decodeIfPresent(YMArtistCounts.self, forKey: .counts)
        self.description = try? container.decodeIfPresent(YMArtistDescription.self, forKey: .description)
    }
}

public struct YMArtistStats: Codable, Sendable {
    public let lastMonthListeners: Int?
    public let lastMonthListenersDelta: Int?

    enum CodingKeys: String, CodingKey {
        case lastMonthListeners
        case lastMonthListenersDelta
    }

    public init(lastMonthListeners: Int? = nil, lastMonthListenersDelta: Int? = nil) {
        self.lastMonthListeners = lastMonthListeners
        self.lastMonthListenersDelta = lastMonthListenersDelta
    }

    private static let listenersFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter
    }()

    public var formattedListeners: String {
        guard let count = lastMonthListeners, count > 0 else { return "" }
        let formattedNumber = Self.listenersFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(formattedNumber) слушателей за месяц"
    }
}

public struct YMArtistCounts: Codable, Sendable {
    public let tracks: Int?
    public let directAlbums: Int?
    public let alsoAlbums: Int?
    public let similarArtists: Int?

    enum CodingKeys: String, CodingKey {
        case tracks
        case directAlbums
        case alsoAlbums
        case similarArtists
    }

    public init(tracks: Int? = nil, directAlbums: Int? = nil, alsoAlbums: Int? = nil, similarArtists: Int? = nil) {
        self.tracks = tracks
        self.directAlbums = directAlbums
        self.alsoAlbums = alsoAlbums
        self.similarArtists = similarArtists
    }
}

public struct YMArtistDescription: Codable, Sendable {
    public let text: String?

    enum CodingKeys: String, CodingKey {
        case text
    }

    public init(text: String? = nil) {
        self.text = text
    }
}
