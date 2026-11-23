import Foundation

/// Reads an M3U playlist.
///
/// The rule this parser exists to keep: one channel out for every stream
/// address in. Lines with the same name, or even the same address, stay as
/// separate entries.
public enum M3U {

    /// True when the bytes look like a playlist and not, say, an error page.
    public static func looksLikePlaylist(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        return head.contains("#EXTM3U") || head.contains("#EXTINF")
    }

    public static func parse(_ data: Data) -> [Channel] {
        var channels: [Channel] = []
        channels.reserveCapacity(max(16, data.count / 300))

        var pending: Header?
        var pendingGroup = ""

        forEachLine(in: data) { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return }

            if line.hasPrefix("#EXTINF") {
                pending = header(from: line)
                return
            }
            if line.hasPrefix("#EXTGRP:") {
                pendingGroup = String(line.dropFirst("#EXTGRP:".count))
                    .trimmingCharacters(in: .whitespaces)
                return
            }
            if line.hasPrefix("#") { return }

            // Anything else is a stream address.
            let head = pending ?? Header()
            let name = head.name.isEmpty ? fallbackName(for: line) : head.name
            let group = head.group.isEmpty ? pendingGroup : head.group
            channels.append(Channel(
                index: channels.count,
                name: name,
                group: group,
                logo: head.logo,
                guideID: head.guideID,
                url: line,
                kind: kind(for: line)))
            pending = nil
            pendingGroup = ""
        }
        return channels
    }

    // MARK: - Pieces

    struct Header {
        var name = ""
        var group = ""
        var logo = ""
        var guideID = ""
    }

    /// `#EXTINF:-1 tvg-id="a" tvg-logo="b" group-title="c",Shown Name`
    static func header(from line: String) -> Header {
        var out = Header()

        // The shown name follows the first comma that is not inside quotes.
        var inQuotes = false
        var comma: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                comma = i
                break
            }
            i = line.index(after: i)
        }

        let attributes: Substring
        if let comma = comma {
            attributes = line[line.startIndex..<comma]
            out.name = String(line[line.index(after: comma)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            // A quote was never closed, or there is no comma at all. Fall back
            // to the last comma so a name is still found where there is one.
            if let last = line.lastIndex(of: ",") {
                attributes = line[line.startIndex..<last]
                out.name = String(line[line.index(after: last)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                attributes = line[...]
            }
        }

        out.group = attribute("group-title", in: attributes)
        out.logo = attribute("tvg-logo", in: attributes)
        out.guideID = attribute("tvg-id", in: attributes)
        if out.name.isEmpty {
            out.name = attribute("tvg-name", in: attributes)
        }
        return out
    }

    static func attribute(_ key: String, in text: Substring) -> String {
        guard let start = text.range(of: key + "=\"") else { return "" }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end])
            .trimmingCharacters(in: .whitespaces)
    }

    /// A film or an episode is a file; a channel is an endless stream.
    public static func kind(for url: String) -> ChannelKind {
        let lower = url.lowercased()
        if lower.contains("/series/") { return .episode }
        if lower.contains("/movie/") || lower.contains("/movies/")
            || lower.contains("/vod/") {
            return .movie
        }
        let path = lower.split(separator: "?", maxSplits: 1,
                               omittingEmptySubsequences: false).first ?? ""
        for ext in [".mp4", ".mkv", ".avi", ".mov", ".m4v", ".wmv", ".flv"]
        where path.hasSuffix(ext) {
            return .movie
        }
        return .live
    }

    /// A line with no `#EXTINF` before it still gets shown. Its name is the
    /// last part of its address, never the whole address, because addresses
    /// carry the account login.
    static func fallbackName(for url: String) -> String {
        let path = url.split(separator: "?", maxSplits: 1,
                             omittingEmptySubsequences: false).first ?? ""
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "Untitled" : last
    }

    /// Walks the bytes one line at a time without building one huge string.
    static func forEachLine(in data: Data, _ body: (String) -> Void) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            var start = 0
            // skip a byte-order mark
            if count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
                start = 3
            }
            var i = start
            while i < count {
                if bytes[i] == 0x0A {
                    if i > start {
                        body(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]),
                                    as: UTF8.self))
                    }
                    start = i + 1
                }
                i += 1
            }
            if start < count {
                body(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<count]),
                            as: UTF8.self))
            }
        }
    }
}
