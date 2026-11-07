import Foundation

public enum YMCoverSize: String, Sendable {
    case small = "100x100"      // Tables and track rows
    case medium = "200x200"     // Cards and playlists
    case artwork = "300x300"    // System NowPlaying / RemoteCommand
    case large = "400x400"      // Now Playing view and Player bar
}

public enum YMCoverURLBuilder {
    /// Converts avatars.yandex.net template URL into a full concrete HTTPS image URL.
    /// Replaces `%%` with the target size, e.g. "100x100" or "400x400".
    public static func buildURL(from coverUri: String?, size: YMCoverSize = .medium) -> URL? {
        guard let coverUri = coverUri, !coverUri.isEmpty else { return nil }

        var uri = coverUri.replacingOccurrences(of: "%%", with: size.rawValue)
        if uri.hasPrefix("http://") {
            uri = "https://" + uri.dropFirst("http://".count)
        } else if uri.hasPrefix("//") {
            uri = "https:" + uri
        } else if !uri.hasPrefix("https://") {
            uri = "https://" + uri
        }
        if let url = URL(string: uri) {
            return url
        }
        let allowed = CharacterSet.urlQueryAllowed
            .union(.urlPathAllowed)
            .union(CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;="))
        if let encoded = uri.addingPercentEncoding(withAllowedCharacters: allowed) {
            return URL(string: encoded)
        }
        return nil
    }
}

/// Helper for decoding String or Int values safely as String.
public enum FlexibleIDDecoder {
    public static func decodeString(from decoder: Decoder) throws -> String {
        let container = try decoder.singleValueContainer()
        if let stringVal = try? container.decode(String.self) {
            return stringVal
        }
        if let intVal = try? container.decode(Int64.self) {
            return String(intVal)
        }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected String or Int for ID"
            )
        )
    }

    public static func decodeStringIfPresent<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, forKey key: Key) -> String? {
        if let str = try? container.decodeIfPresent(String.self, forKey: key) {
            return str
        }
        if let int = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(int)
        }
        return nil
    }
}
