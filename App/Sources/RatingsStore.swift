import Foundation
import TuberCore

/// Ratings for films and shows, from the provider's own catalogue.
///
/// The playlist carries no ratings, so they are asked for separately: two
/// small requests, at most once a day, and never sooner than an hour after
/// one that failed. The login is taken from the saved playlist link, used
/// for those requests and nothing else, and is never written out or logged.
final class RatingsStore {
    static let shared = RatingsStore()
    static let didChange = Notification.Name("TuberView.Ratings.didChange")

    static let refreshAge: TimeInterval = 24 * 3600
    static let retryAge: TimeInterval = 3600

    struct Saved: Codable {
        var fetched: Double = 0
        var tried: Double = 0
        /// By the provider's number for the film.
        var movies: [String: Double] = [:]
        /// By the show's name, reduced to letters and digits.
        var series: [String: Double] = [:]
        /// Films by name, for a provider whose catalogue numbers differ
        /// from the ones in the playlist. Absent in a file from before.
        var titles: [String: Double]?
    }

    private var saved = Saved()
    private var isLoading = false
    /// What the last attempt found, in words that are safe to print: never
    /// an address or a login.
    private(set) var report: [String] = []
    private var demo = false
    private let work = DispatchQueue(label: "tuberview.ratings", qos: .utility)
    private var file: URL { ConfigStore.shared.directory.appendingPathComponent("ratings.json") }
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 240
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private init() {
        if let data = try? Data(contentsOf: file),
           let read = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = read
        }
    }

    var counts: (movies: Int, series: Int) { (saved.movies.count, saved.series.count) }
    var hasFetched: Bool { saved.fetched > 0 && saved.titles != nil }
    var isBusy: Bool { isLoading }

    /// The ratings as they stand, to be read on any thread.
    struct Lookup {
        fileprivate let saved: Saved

        func movie(url: String, name: String) -> Double? {
            movieByNumber(url: url) ?? movieByName(name)
        }

        func movieByNumber(url: String) -> Double? {
            saved.movies[Titles.streamID(url)]
        }

        func movieByName(_ name: String) -> Double? {
            guard let titles = saved.titles else { return nil }
            if let found = titles[Titles.key(name)] { return found }
            let parsed = Titles.movie(name)
            let key = Titles.key(parsed.title)
            if key.isEmpty { return nil }
            if let year = parsed.year, let found = titles["\(key)|\(year)"] { return found }
            return titles[key + "|"]
        }

        func show(name: String) -> Double? {
            if let found = saved.series[Titles.key(name)] { return found }
            let bare = Titles.movie(name).title
            return bare == name ? nil : saved.series[Titles.key(bare)]
        }
    }

    var lookup: Lookup { Lookup(saved: saved) }

    func movie(url: String, name: String) -> Double? { lookup.movie(url: url, name: name) }
    func movieByNumber(url: String) -> Double? { lookup.movieByNumber(url: url) }
    func movieByName(_ name: String) -> Double? { lookup.movieByName(name) }
    func show(name: String) -> Double? { lookup.show(name: name) }

    static func text(_ rating: Double?) -> String? {
        guard let rating = rating, rating > 0 else { return nil }
        return String(format: "%.1f", rating)
    }

    /// For the pictures taken by the cloud build. Nothing is saved.
    func installDemo(movies: [String: Double], series: [String: Double]) {
        demo = true
        saved.movies = movies
        saved.series = series
        NotificationCenter.default.post(name: RatingsStore.didChange, object: self)
    }

    /// Fetch ratings if they are due. Call once the playlist is loaded.
    func refreshIfDue(force: Bool = false) {
        guard !demo, !isLoading else { return }
        let now = Date().timeIntervalSince1970
        if saved.titles != nil && now - saved.fetched < RatingsStore.refreshAge && saved.fetched <= now { return }
        if !force && now - saved.tried < RatingsStore.retryAge && saved.tried <= now { return }
        report = []
        let bases = endpoints()
        guard !bases.isEmpty else {
            report.append("no login could be read from the playlist link or a film's address")
            return
        }
        isLoading = true
        saved.tried = now
        save()
        connect(bases, at: 0) { [weak self] found in
            guard let self = self else { return }
            guard let (base, agent) = found else {
                self.isLoading = false
                return
            }
            self.load(base, agent: agent)
        }
    }

    /// Ask each candidate address, with each way of introducing ourselves,
    /// whether it knows the login. The first that does is used. At most six
    /// small requests, and usually one.
    private func connect(_ bases: [URLComponents], at index: Int,
                         done: @escaping ((URLComponents, String)?) -> Void) {
        let agents = RatingsStore.agents
        let total = bases.count * agents.count
        guard index < total else {
            done(nil)
            return
        }
        let base = bases[index / agents.count]
        let agent = agents[index % agents.count]
        let label = "sign-in check \(index + 1) of \(total)"
        request(base, action: nil, agent: agent, label: label) { [weak self] json in
            guard let self = self else { return }
            if let object = json as? [String: Any], let info = object["user_info"] as? [String: Any] {
                let auth = RatingsStore.number(info["auth"]) ?? 0
                self.report.append("\(label): the provider knows the login: \(auth == 1 ? "yes" : "no")")
                if auth == 1 {
                    done((base, agent))
                    return
                }
            }
            self.connect(bases, at: index + 1, done: done)
        }
    }

    private func load(_ base: URLComponents, agent: String) {
        fetch(base, action: "get_vod_streams", agent: agent) { [weak self] films in
            guard let self = self else { return }
            self.fetch(base, action: "get_series", agent: agent) { shows in
                self.isLoading = false
                guard films != nil || shows != nil else { return }
                var movies: [String: Double] = [:]
                var titles: [String: Double] = [:]
                for row in films ?? [] {
                    guard let rating = RatingsStore.rating(row) else { continue }
                    if let id = RatingsStore.id(row["stream_id"]) { movies[id] = rating }
                    guard let name = row["name"] as? String else { continue }
                    let whole = Titles.key(name)
                    if !whole.isEmpty { titles[whole] = rating }
                    let parsed = Titles.movie(name)
                    let key = Titles.key(parsed.title)
                    if !key.isEmpty {
                        let dated = key + "|" + (parsed.year.map { String($0) } ?? "")
                        if titles[dated] == nil { titles[dated] = rating }
                    }
                }
                var series: [String: Double] = [:]
                for row in shows ?? [] {
                    guard let name = row["name"] as? String,
                          let rating = RatingsStore.rating(row) else { continue }
                    let key = Titles.key(name)
                    if !key.isEmpty { series[key] = rating }
                    let bare = Titles.key(Titles.movie(name).title)
                    if !bare.isEmpty && series[bare] == nil { series[bare] = rating }
                }
                self.report.append("ratings read: \(movies.count) films, \(series.count) shows")
                if films != nil {
                    self.saved.movies = movies
                    self.saved.titles = titles
                }
                if shows != nil { self.saved.series = series }
                if films != nil && shows != nil {
                    self.saved.fetched = Date().timeIntervalSince1970
                }
                self.save()
                NotificationCenter.default.post(name: RatingsStore.didChange, object: self)
            }
        }
    }

    // MARK: - Private

    private func save() {
        guard !demo, let data = try? JSONEncoder().encode(saved) else { return }
        let target = file
        work.async {
            try? data.write(to: target, options: .atomic)
            ConfigStore.lock(target)
        }
    }

    private static let agents = ["Tuner/2.1", "VLC/3.0.20 LibVLC/3.0.20"]
    private static let pathKinds: Set<String> = ["m3u", "get", "live", "movie", "series", "vod"]

    /// The provider's catalogue address with the login. The playlist link is
    /// tried first, because films are often served from another machine that
    /// does not answer catalogue questions; a film's address is the fallback.
    /// Held in memory only.
    private func endpoints() -> [URLComponents] {
        var found: [URLComponents] = []
        func add(_ parts: URLComponents, _ user: String?, _ pass: String?) {
            guard let u = user, let p = pass,
                  !u.isEmpty, !p.isEmpty, parts.host != nil else { return }
            var base = URLComponents()
            base.scheme = parts.scheme
            base.host = parts.host
            base.port = parts.port
            base.path = "/player_api.php"
            base.queryItems = [URLQueryItem(name: "username", value: u),
                               URLQueryItem(name: "password", value: p)]
            if !found.contains(where: { $0.host == base.host && $0.port == base.port
                && $0.scheme == base.scheme && $0.queryItems == base.queryItems }) {
                found.append(base)
            }
        }
        let source = ConfigStore.shared.config.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Library.webURL(from: source),
           let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let pieces = url.pathComponents.filter { $0 != "/" }
            let items = parts.queryItems ?? []
            var how = "no"
            if pieces.count >= 3, RatingsStore.pathKinds.contains(pieces[0].lowercased()) {
                add(parts, pieces[1], pieces[2])
                how = "yes, in the path"
            }
            let user = items.first(where: { $0.name == "username" })?.value
            let pass = items.first(where: { $0.name == "password" })?.value
            if user != nil && pass != nil {
                add(parts, user, pass)
                how = how == "no" ? "yes, after the question mark" : how
            }
            report.append("playlist link: a web address with \(pieces.count) path parts and \(items.count) parts after the question mark; login found: \(how)")
        } else {
            report.append("playlist link: not a web address")
        }
        let sample = Library.shared.channels.first(where: { $0.kind != .live })
            ?? Library.shared.channels.first
        if let sample = sample, let url = Library.webURL(from: sample.url),
           let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let pieces = url.pathComponents.filter { $0 != "/" }
            let before = found.count
            // movie/<user>/<pass>/<number>, or <user>/<pass>/<number>
            var user: String?
            var pass: String?
            if pieces.count >= 4 {
                user = pieces[pieces.count - 3]
                pass = pieces[pieces.count - 2]
            } else if pieces.count == 3 {
                user = pieces[0]
                pass = pieces[1]
            }
            // the playlist link's machine is the one that answers catalogue
            // questions, so ask it first with the login the films carry
            if let home = Library.webURL(from: source),
               let homeParts = URLComponents(url: home, resolvingAgainstBaseURL: false) {
                add(homeParts, user, pass)
            }
            add(parts, user, pass)
            let same = found.first.map { $0.host == parts.host } ?? false
            report.append("film address: \(pieces.count) parts; \(found.count > before ? "gives another place to ask" : "adds nothing new"); same machine as the playlist link: \(same ? "yes" : "no")")
        }
        return found
    }

    /// One catalogue request. `done` gets the rows on the main thread, or
    /// nil when the answer was not a list.
    private func fetch(_ base: URLComponents, action: String, agent: String,
                       done: @escaping ([[String: Any]]?) -> Void) {
        request(base, action: action, agent: agent, label: action) { json in
            done(json as? [[String: Any]])
        }
    }

    /// One request to the catalogue. `done` gets what the answer held, on the
    /// main thread, or nil. The note it leaves describes the answer's shape
    /// and never its words.
    private func request(_ base: URLComponents, action: String?, agent: String, label: String,
                         done: @escaping (Any?) -> Void) {
        var parts = base
        if let action = action {
            parts.queryItems = (parts.queryItems ?? []) + [URLQueryItem(name: "action", value: action)]
        }
        guard let url = parts.url else {
            done(nil)
            return
        }
        var ask = URLRequest(url: url)
        ask.setValue(agent, forHTTPHeaderField: "User-Agent")
        ask.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        let asked = url.host
        let task = session.dataTask(with: ask) { [work] data, response, error in
            work.async {
                var result: Any?
                var note = label + ": "
                if let error = error {
                    // the code only: the description can carry the address
                    note += "failed, error \((error as NSError).domain) \((error as NSError).code)"
                } else {
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    note += "answer \(status), \(data?.count ?? 0) bytes"
                    if let kind = http?.value(forHTTPHeaderField: "Content-Type") {
                        note += ", sent as \(kind.prefix(40))"
                    }
                    if let host = http?.url?.host, host != asked {
                        note += ", answered by another machine"
                    }
                    if let data = data, (200..<300).contains(status) {
                        if let json = RatingsStore.read(data) {
                            result = json
                            if let list = json as? [[String: Any]] {
                                note += ", a list of \(list.count)"
                                if let first = list.first {
                                    note += ", fields: \(first.keys.sorted().prefix(24).joined(separator: " "))"
                                }
                            } else if let object = json as? [String: Any] {
                                note += ", an object with fields: \(object.keys.sorted().prefix(12).joined(separator: " "))"
                            } else if let list = json as? [Any] {
                                note += ", a list of \(list.count) of another shape"
                            } else {
                                note += ", another shape"
                            }
                        } else {
                            note += ", not readable as data, " + RatingsStore.shape(data)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.report.append(note)
                    done(result)
                }
            }
        }
        task.resume()
    }

    /// Read an answer as data, forgiving a leading mark, stray text before
    /// the data, and letters that are not valid UTF-8.
    private static func read(_ data: Data) -> Any? {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let open = text[start]
        guard let end = text.lastIndex(of: open == "[" ? "]" : "}"), end > start else { return nil }
        // a web page also has braces: only accept text that starts near the top
        guard text.distance(from: text.startIndex, to: start) < 400,
              !text[..<start].contains("<") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))
    }

    /// What kind of thing an unreadable answer is, without quoting it.
    private static func shape(_ data: Data) -> String {
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var kind: String
        if trimmed.isEmpty { kind = "empty" }
        else if trimmed.hasPrefix("<") { kind = "a web page" }
        else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { kind = "looks like data but is damaged" }
        else if trimmed.hasPrefix("#extm3u") { kind = "a playlist" }
        else { kind = "plain text" }
        var signs: [String] = []
        for (word, meaning) in [("cloudflare", "a protection service"), ("captcha", "a human check"),
                                ("403", "says forbidden"), ("forbidden", "says forbidden"),
                                ("404", "says not found"), ("not found", "says not found"),
                                ("nginx", "the web server's own page"), ("apache", "the web server's own page"),
                                ("blocked", "says blocked"), ("denied", "says denied"),
                                ("expired", "says expired"), ("disabled", "says disabled"),
                                ("javascript", "wants a browser")] where trimmed.contains(word) {
            if !signs.contains(meaning) { signs.append(meaning) }
        }
        if !signs.isEmpty { kind += " (" + signs.joined(separator: ", ") + ")" }
        return kind
    }

    private static func id(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// A rating out of ten, or nil when the provider has none.
    private static func rating(_ row: [String: Any]) -> Double? {
        var value = number(row["rating"]) ?? 0
        if value <= 0, let five = number(row["rating_5based"]), five > 0 { value = five * 2 }
        guard value > 0, value <= 10 else { return nil }
        return (value * 10).rounded() / 10
    }
}
