import Foundation

/// A single timestamped line in synchronized karaoke lyrics.
public struct SyncedLyricLine: Identifiable, Sendable, Hashable {
    public let id: Int
    public let time: TimeInterval
    public let text: String

    public init(id: Int, time: TimeInterval, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }

    public var formattedTimestamp: String {
        let total = Int(time)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// Structured synchronized LRC lyrics container with fast active-line lookup and parsing.
public struct YMSyncedLyrics: Sendable, Hashable {
    public let lines: [SyncedLyricLine]

    public init(lines: [SyncedLyricLine]) {
        self.lines = lines
    }

    public var isEmpty: Bool {
        lines.isEmpty
    }

    /// Finds the index of the active lyric line for the given playback time in seconds.
    public func activeLineIndex(for currentTime: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }

        // Before first line
        if currentTime < lines[0].time {
            return nil
        }

        // Binary search for highest index where line.time <= currentTime
        var low = 0
        var high = lines.count - 1
        var result = 0

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= currentTime {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result
    }

    /// Parses standard LRC format text into chronological SyncedLyricLine array.
    /// Handles multiple timestamp tags per line (e.g. `[00:12.30][00:24.50] Refrain`)
    /// and millisecond fractions (`.xx` or `.xxx`).
    public static func parse(lrcContent: String) -> YMSyncedLyrics {
        var parsed: [(time: TimeInterval, text: String)] = []

        let rawLines = lrcContent.components(separatedBy: .newlines)
        let tagRegex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]")

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip ID3/LRC header tags like [ti:], [ar:], [al:], [by:], [offset:]
            if trimmed.hasPrefix("[ti:") || trimmed.hasPrefix("[ar:") ||
               trimmed.hasPrefix("[al:") || trimmed.hasPrefix("[by:") ||
               trimmed.hasPrefix("[offset:") || trimmed.hasPrefix("[length:") ||
               trimmed.hasPrefix("[re:") || trimmed.hasPrefix("[ve:") {
                continue
            }

            guard let regex = tagRegex else { continue }
            let nsString = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsString.length))
            guard !matches.isEmpty else { continue }

            var lastTagEnd = 0
            var timestamps: [TimeInterval] = []

            for match in matches {
                lastTagEnd = max(lastTagEnd, match.range.location + match.range.length)

                if match.numberOfRanges >= 3 {
                    let minStr = nsString.substring(with: match.range(at: 1))
                    let secStr = nsString.substring(with: match.range(at: 2))
                    let minutes = Double(minStr) ?? 0.0
                    let seconds = Double(secStr) ?? 0.0
                    var fraction = 0.0

                    if match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound {
                        let fracStr = nsString.substring(with: match.range(at: 3))
                        if let f = Double("0.\(fracStr)") {
                            fraction = f
                        }
                    }

                    let totalSeconds = (minutes * 60.0) + seconds + fraction
                    timestamps.append(totalSeconds)
                }
            }

            let text: String
            if lastTagEnd < nsString.length {
                text = nsString.substring(from: lastTagEnd).trimmingCharacters(in: .whitespaces)
            } else {
                text = ""
            }

            for t in timestamps {
                parsed.append((time: t, text: text))
            }
        }

        guard !parsed.isEmpty else {
            return YMSyncedLyrics(lines: [])
        }

        // Sort chronologically
        parsed.sort { $0.time < $1.time }

        var result: [SyncedLyricLine] = []
        var idCounter = 0

        for item in parsed {
            // If empty line, preserve as instrumental indicator if not consecutive
            let text = item.text.isEmpty ? "•••" : item.text
            result.append(SyncedLyricLine(id: idCounter, time: item.time, text: text))
            idCounter += 1
        }

        return YMSyncedLyrics(lines: result)
    }
}
