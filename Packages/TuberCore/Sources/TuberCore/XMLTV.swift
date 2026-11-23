import Foundation

/// One show in the guide.
public struct Programme: Equatable, Sendable {
    public let start: TimeInterval
    public let stop: TimeInterval
    public let title: String

    public init(start: TimeInterval, stop: TimeInterval, title: String) {
        self.start = start
        self.stop = stop
        self.title = title
    }
}

/// Reads a guide in the XMLTV format that providers publish.
///
/// A guide can be tens of megabytes covering a week. It is read as a stream
/// and only the shows inside the wanted window are kept.
public enum XMLTV {

    /// "20261122153000 +0100" as seconds since 1970, or nil.
    public static func time(_ text: String) -> TimeInterval? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 14 else { return nil }
        var digits = [Int](repeating: 0, count: 14)
        for i in 0..<14 {
            let d = Int(bytes[i]) - 48
            guard d >= 0 && d <= 9 else { return nil }
            digits[i] = d
        }
        let year = digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3]
        let month = digits[4] * 10 + digits[5]
        let day = digits[6] * 10 + digits[7]
        let hour = digits[8] * 10 + digits[9]
        let minute = digits[10] * 10 + digits[11]
        let second = digits[12] * 10 + digits[13]
        guard month >= 1, month <= 12, day >= 1, day <= 31, hour < 24, minute < 60, second < 61 else {
            return nil
        }
        // days since 1970-01-01, the usual civil-date arithmetic
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        var seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second)

        // an offset such as " +0100" or " -0530" may follow
        var i = 14
        while i < bytes.count && bytes[i] == 32 { i += 1 }
        if i + 4 < bytes.count, bytes[i] == 43 || bytes[i] == 45 {
            var o = [Int](repeating: 0, count: 4)
            for k in 0..<4 {
                let d = Int(bytes[i + 1 + k]) - 48
                guard d >= 0 && d <= 9 else { return seconds }
                o[k] = d
            }
            let offset = Double((o[0] * 10 + o[1]) * 3600 + (o[2] * 10 + o[3]) * 60)
            seconds += bytes[i] == 43 ? -offset : offset
        }
        return seconds
    }

    /// A guide as read: the shows, and the names its channels answer to.
    public struct Guide: Sendable {
        /// Shows by channel id (lower case), in time order.
        public var shows: [String: [Programme]] = [:]
        /// Channel id (lower case) for each id and each form of each name.
        public var aliases: [String: String] = [:]

        public init() {}

        /// The guide channel for a playlist entry, or nil. A guide names
        /// channels by its own ids and a provider names the same channel a
        /// dozen ways, so the playlist's id is tried first, then the name,
        /// then the name with region and quality words taken off. Only a
        /// channel that has shows counts.
        public func channel(guideID: String, name: String) -> String? {
            var candidates: [String] = []
            let id = guideID.trimmingCharacters(in: .whitespaces).lowercased()
            if !id.isEmpty { candidates.append(id) }
            candidates += XMLTV.keys(forName: name)
            for candidate in candidates {
                if let found = aliases[candidate], shows[found] != nil { return found }
                if shows[candidate] != nil { return candidate }
            }
            return nil
        }
    }

    // "US:", "[UK] -", "CA |"
    private static let prefix = try! NSRegularExpression(
        pattern: #"^\s*(?:\[[^\]]*\]|\([^)]*\))?\s*[A-Z]{2,4}\s*[:|\-]\s*"#)
    // "(D)", "[Backup]"
    private static let brackets = try! NSRegularExpression(pattern: #"\([^)]*\)|\[[^\]]*\]"#)
    // picture quality on its own: "HD", "4K"
    private static let quality = try! NSRegularExpression(
        pattern: #"\b(hd|fhd|uhd|4k|sd|hq)\b"#, options: [.caseInsensitive])
    // region and quality words that differ between a guide and a playlist
    private static let suffix = try! NSRegularExpression(
        pattern: #"\b(hd|fhd|uhd|4k|sd|hq|east|west|usa|us|uk|ca|raw|feed|plus|network|tv|channel)\b"#,
        options: [.caseInsensitive])

    private static func strip(_ regex: NSRegularExpression, from text: String, with: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                       withTemplate: with)
    }

    private static func squash(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars
        where (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// The forms of a channel name used for matching, most exact first:
    /// "US: USA Network (D)" gives "usanetworkd", "usanetwork". A guide's
    /// "USA Network HD" gives "usanetworkhd", "usanetwork", so they meet.
    public static func keys(forName name: String) -> [String] {
        let bare = strip(prefix, from: name, with: "")
        let plain = strip(brackets, from: bare, with: " ")
        var out: [String] = []
        for key in [squash(bare), squash(plain), squash(strip(quality, from: plain, with: " ")),
                    squash(strip(suffix, from: plain, with: " "))]
        where key.count > 1 && !out.contains(key) {
            out.append(key)
        }
        return out
    }

    /// Read a guide: every show that overlaps the window, and the channel
    /// names.
    public static func read(stream: InputStream, from: TimeInterval, to: TimeInterval,
                            cancelled: @escaping () -> Bool = { false }) -> Guide {
        let reader = Reader(from: from, to: to, cancelled: cancelled)
        let parser = XMLParser(stream: stream)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var guide = Guide()
        guide.shows = reader.found
        for key in guide.shows.keys {
            guide.shows[key]?.sort { $0.start < $1.start }
        }
        guide.aliases = reader.aliases
        return guide
    }

    /// Every show that overlaps the window, by channel id (lower case), in
    /// time order.
    public static func parse(stream: InputStream, from: TimeInterval, to: TimeInterval,
                             cancelled: @escaping () -> Bool = { false }) -> [String: [Programme]] {
        read(stream: stream, from: from, to: to, cancelled: cancelled).shows
    }

    public static func parse(_ data: Data, from: TimeInterval, to: TimeInterval) -> [String: [Programme]] {
        parse(stream: InputStream(data: data), from: from, to: to)
    }

    /// What is on at `now`, and what follows it.
    public static func nowAndNext(in shows: [Programme], at now: TimeInterval) -> (now: Programme?, next: Programme?) {
        var current: Programme?
        var following: Programme?
        for show in shows {
            if show.start <= now && now < show.stop {
                current = show
            } else if show.start > now {
                following = show
                break
            }
        }
        return (current, following)
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let from: TimeInterval
        let to: TimeInterval
        let cancelled: () -> Bool
        var found: [String: [Programme]] = [:]
        var aliases: [String: String] = [:]
        /// How exact the claim on each alias is: 0 is the name as written.
        private var rank: [String: Int] = [:]

        /// The `<channel>` being read, and its name so far.
        private var listing = ""
        private var inName = false
        private var name = ""

        private var channel = ""
        private var start: TimeInterval = 0
        private var stop: TimeInterval = 0
        private var wanted = false
        private var inTitle = false
        private var hasTitle = false
        private var title = ""
        private var seen = 0

        init(from: TimeInterval, to: TimeInterval, cancelled: @escaping () -> Bool) {
            self.from = from
            self.to = to
            self.cancelled = cancelled
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "programme" {
                seen += 1
                if seen & 0x3FFF == 0 && cancelled() {
                    parser.abortParsing()
                    return
                }
                wanted = false
                hasTitle = false
                title = ""
                guard let id = attributes["channel"], !id.isEmpty,
                      let s = XMLTV.time(attributes["start"] ?? "") else { return }
                let e = XMLTV.time(attributes["stop"] ?? "") ?? (s + 3600)
                guard e > from && s < to && e > s else { return }
                channel = id.lowercased()
                start = s
                stop = e
                wanted = true
            } else if name == "title" && wanted && !hasTitle {
                inTitle = true
                title = ""
            } else if name == "channel" {
                listing = (attributes["id"] ?? "").lowercased()
                if !listing.isEmpty && aliases[listing] == nil { aliases[listing] = listing }
            } else if name == "display-name" && !listing.isEmpty {
                inName = true
                self.name = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTitle { title += string }
            if inName { name += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == "display-name" && inName {
                inName = false
                // The channel whose own name is closest keeps a name:
                // "USA Network HD" beats "USA Network HD (Pacific)" for
                // "usanetwork". Between equals the first keeps it.
                for (place, key) in XMLTV.keys(forName: self.name).enumerated() {
                    if let held = rank[key], held <= place { continue }
                    if aliases[key] != nil && rank[key] == nil { continue }
                    aliases[key] = listing
                    rank[key] = place
                }
            } else if name == "channel" {
                listing = ""
            } else if name == "title" && inTitle {
                inTitle = false
                hasTitle = true
            } else if name == "programme" && wanted {
                wanted = false
                let shown = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !shown.isEmpty else { return }
                found[channel, default: []].append(Programme(start: start, stop: stop, title: shown))
            }
        }
    }
}
