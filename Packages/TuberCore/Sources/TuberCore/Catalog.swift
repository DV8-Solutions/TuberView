import Foundation

/// Reading what a provider packs into names and categories.
public enum Titles {

    /// The genres in a category such as "Crime;Drama;TV Crime". A provider
    /// joins several with ";" and repeats some with "TV " in front; here
    /// they come back once each, in the order written.
    public static func genres(_ group: String) -> [String] {
        var out: [String] = []
        for piece in group.split(separator: ";") {
            var name = piece.trimmingCharacters(in: .whitespaces)
            if name.count > 3 && name.lowercased().hasPrefix("tv ") {
                name = String(name.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            if name.isEmpty { continue }
            if !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                out.append(name)
            }
        }
        return out
    }

    /// "Rambo III 1988" or "Rambo III (1988)" as a title and a year. A name
    /// that is only a year, or has none, comes back whole.
    public static func movie(_ name: String) -> (title: String, year: Int?) {
        var text = name.trimmingCharacters(in: .whitespaces)
        var closing = false
        if text.hasSuffix(")") {
            closing = true
            text.removeLast()
        }
        let tail = text.suffix(4)
        guard tail.count == 4, let year = Int(tail), year >= 1900, year <= 2035,
              tail.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return (name.trimmingCharacters(in: .whitespaces), nil)
        }
        var head = text.dropLast(4)
        if closing {
            guard head.hasSuffix("(") else { return (name.trimmingCharacters(in: .whitespaces), nil) }
            head = head.dropLast()
        }
        guard let last = head.last, last == " " || last == "-" || last == "." else {
            return (name.trimmingCharacters(in: .whitespaces), nil)
        }
        let title = head.trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        if title.isEmpty { return (name.trimmingCharacters(in: .whitespaces), nil) }
        return (title, year)
    }

    /// "The Rainmaker S01E04" as a show, a season and an episode. Nil when
    /// the name carries no such mark.
    public static func episode(_ name: String) -> (show: String, season: Int, episode: Int)? {
        let chars = Array(name)
        var i = chars.count - 1
        // the last "S<digits>E<digits>" in the name, with an optional space
        while i >= 3 {
            defer { i -= 1 }
            guard chars[i].isASCII, chars[i].isNumber else { continue }
            var end = i
            var e = 0
            var scale = 1
            var digits = 0
            while end >= 0, chars[end].isASCII, let d = chars[end].wholeNumberValue, digits < 4 {
                e += d * scale
                scale *= 10
                digits += 1
                end -= 1
            }
            guard end >= 2, chars[end] == "E" || chars[end] == "e" else { continue }
            end -= 1
            while end >= 0, chars[end] == " " { end -= 1 }
            var s = 0
            scale = 1
            digits = 0
            while end >= 0, chars[end].isASCII, let d = chars[end].wholeNumberValue, digits < 4 {
                s += d * scale
                scale *= 10
                digits += 1
                end -= 1
            }
            guard digits > 0, end >= 0, chars[end] == "S" || chars[end] == "s" else { continue }
            // "S" must start a word, so "Paris 2E1" is not season 2
            if end > 0, chars[end - 1].isLetter || chars[end - 1].isNumber { continue }
            let show = String(chars[0..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " -.:|"))
            if show.isEmpty { return nil }
            return (show, s, e)
        }
        return nil
    }

    /// A name reduced to its letters and digits, for telling that two
    /// spellings are the same show.
    public static func key(_ name: String) -> String {
        String(Search.fold(name).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The number a provider gives a film or an episode: the last part of
    /// its address without the ending. Never the login before it.
    public static func streamID(_ url: String) -> String {
        var part = url
        if let q = part.firstIndex(of: "?") { part = String(part[..<q]) }
        if let slash = part.lastIndex(of: "/") { part = String(part[part.index(after: slash)...]) }
        if let dot = part.lastIndex(of: ".") { part = String(part[..<dot]) }
        return part
    }
}

/// A film as one tile.
public struct MovieItem: Equatable, Sendable {
    /// Position of its entry in the playlist.
    public let channel: Int
    public let title: String
    public let year: Int?
    public internal(set) var genres: [String]
    public let folded: String
}

/// One episode of a show.
public struct EpisodeRef: Equatable, Sendable {
    public let season: Int
    public let episode: Int
    /// Position of its entry in the playlist.
    public let channel: Int
}

/// A show as one tile, holding its episodes.
public struct ShowItem: Equatable, Sendable {
    public let name: String
    public internal(set) var poster: String
    public internal(set) var genres: [String]
    /// In season then episode order.
    public internal(set) var episodes: [EpisodeRef]
    public let folded: String

    public var seasons: [Int] {
        var seen: [Int] = []
        for e in episodes where seen.last != e.season { seen.append(e.season) }
        return seen
    }
}

/// The films and shows of a playlist arranged for browsing. The playlist
/// itself is untouched: this only says which entries belong together. An
/// entry the provider lists again under another category, with the very
/// same address, is one tile filed under both; entries with different
/// addresses always stay separate.
public struct Catalog: Sendable {
    public var movies: [MovieItem] = []
    public var shows: [ShowItem] = []
    public var movieGenres: [GroupCount] = []
    public var showGenres: [GroupCount] = []
    /// For each episode address, which show holds it.
    public var showOfEpisode: [String: Int] = [:]
    /// Playlist position by address, first mention.
    public var position: [String: Int] = [:]

    public init() {}

    public static func build(from channels: [Channel], cancelled: () -> Bool = { false }) -> Catalog? {
        var out = Catalog()
        var movieAt: [String: Int] = [:]
        var showAt: [String: Int] = [:]
        var episodeSeen = Set<String>()
        var loose: [Int: Int] = [:]
        out.position.reserveCapacity(channels.count)

        for (i, channel) in channels.enumerated() {
            if i & 0x3FFF == 0 && cancelled() { return nil }
            if out.position[channel.url] == nil { out.position[channel.url] = i }
            switch channel.kind {
            case .live:
                continue
            case .movie:
                let genres = Titles.genres(channel.group)
                if let at = movieAt[channel.url] {
                    for g in genres where !out.movies[at].genres.contains(g) {
                        out.movies[at].genres.append(g)
                    }
                    continue
                }
                let parsed = Titles.movie(channel.name)
                movieAt[channel.url] = out.movies.count
                out.movies.append(MovieItem(channel: i, title: parsed.title, year: parsed.year,
                                            genres: genres, folded: Search.fold(parsed.title)))
            case .episode:
                let genres = Titles.genres(channel.group)
                let parsed = Titles.episode(channel.name)
                let name = parsed?.show ?? channel.name
                let key = Titles.key(name)
                let at: Int
                if let known = showAt[key] {
                    at = known
                    for g in genres where !out.shows[at].genres.contains(g) {
                        out.shows[at].genres.append(g)
                    }
                    if out.shows[at].poster.isEmpty { out.shows[at].poster = channel.logo }
                } else {
                    at = out.shows.count
                    showAt[key] = at
                    out.shows.append(ShowItem(name: name, poster: channel.logo, genres: genres,
                                              episodes: [], folded: Search.fold(name)))
                }
                if episodeSeen.insert(channel.url).inserted {
                    let season = parsed?.season ?? 0
                    var number = parsed?.episode ?? 0
                    if parsed == nil {
                        number = (loose[at] ?? 0) + 1
                        loose[at] = number
                    }
                    out.shows[at].episodes.append(EpisodeRef(season: season, episode: number, channel: i))
                    out.showOfEpisode[channel.url] = at
                }
            }
        }
        if cancelled() { return nil }
        for i in out.shows.indices {
            out.shows[i].episodes.sort {
                if $0.season != $1.season { return $0.season < $1.season }
                if $0.episode != $1.episode { return $0.episode < $1.episode }
                return $0.channel < $1.channel
            }
        }
        out.movieGenres = count(out.movies.map(\.genres))
        out.showGenres = count(out.shows.map(\.genres))
        return out
    }

    /// Genres with how many tiles each holds: the provider's "Latest"
    /// shelves first, then the rest by name.
    static func count(_ lists: [[String]]) -> [GroupCount] {
        var counts: [String: Int] = [:]
        for list in lists {
            for g in list { counts[g, default: 0] += 1 }
        }
        func latest(_ name: String) -> Bool { name.lowercased().contains("latest") }
        let names = counts.keys.sorted {
            let a = latest($0), b = latest($1)
            if a != b { return a }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return names.map { GroupCount(name: $0, count: counts[$0] ?? 0) }
    }
}
