import Foundation
import CryptoKit

/// Signs Yandex Music audio stream URLs using MD5 hashing according to official client specification.
public enum YMAudioURLSigner {
    /// Secret salt constant used by official Yandex Music clients
    public static let secretSalt = "XGRlBW9FXlekgbPrRHuSiA"

    /// Secret key constant for HMAC-SHA256 signing of /get-file-info (Lossless / 320 kbps)
    public static let fileInfoSecretKey = "p93jhgh689SBReK6ghtw62"

    /// Computes HMAC-SHA256 signature for GET /get-file-info
    /// Formula: HMAC<SHA256>(secretKey, "\(ts)\(trackId)\(quality)\(codecsWithoutCommas)\(transportsWithoutCommas)")
    /// Signature: Base64 representation without trailing '=' (first 43 characters).
    public static func computeFileInfoSign(
        ts: String,
        trackId: String,
        quality: String,
        codecs: String = "flac,flac-mp4,mp3,aac,he-aac,aac-mp4",
        transports: String = "raw"
    ) -> String {
        let codecsWithoutCommas = codecs.replacingOccurrences(of: ",", with: "")
        let transportsWithoutCommas = transports.replacingOccurrences(of: ",", with: "")
        let stringToSign = "\(ts)\(trackId)\(quality)\(codecsWithoutCommas)\(transportsWithoutCommas)"
        let key = SymmetricKey(data: Data(fileInfoSecretKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        let base64 = Data(signature).base64EncodedString()
        return String(base64.prefix(43))
    }

    /// Computes HMAC-SHA256 signature for GET /tracks/{trackId}/lyrics?format=LRC
    /// Formula: HMAC<SHA256>(secretKey, "\(numericTrackId)\(timestamp)")
    /// Signature: standard Base64 representation.
    public static func computeLyricsSign(trackId: String, timestamp: Int) -> String {
        let numericTrackId = trackId.components(separatedBy: ":").first ?? trackId
        let message = "\(numericTrackId)\(timestamp)"
        let key = SymmetricKey(data: Data(fileInfoSecretKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(signature).base64EncodedString()
    }

    /// Computes MD5 hex digest string (lowercase) from raw string data.
    public static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes sign hash from path and salt 's' according to formula:
    /// "XGRlBW9FXlekgbPrRHuSiA" + String(path.dropFirst()) + s
    public static func computeSign(path: String, s: String) -> String {
        let strippedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let stringToHash = secretSalt + strippedPath + s
        return md5Hex(stringToHash)
    }

    /// Generates the direct HTTPS download/streaming URL for the track.
    /// Format: `https://\(host)/get-mp3/\(sign)/\(ts)\(path)`
    public static func signStream(host: String, path: String, ts: String, s: String) -> URL? {
        let sign = computeSign(path: path, s: s)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let urlString = "https://\(host)/get-mp3/\(sign)/\(ts)\(normalizedPath)"
        return URL(string: urlString)
    }

    /// Convenience overload using `YMStreamData`
    public static func signStream(from streamData: YMStreamData) -> URL? {
        signStream(
            host: streamData.host,
            path: streamData.path,
            ts: streamData.ts,
            s: streamData.s
        )
    }
}
