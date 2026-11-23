import Foundation
import TuberCore

/// This week's most popular films and shows, from TMDB's public chart.
///
/// It is what the Top 10 rows are picked from. The chart is asked for at
/// most once a day, with the key entered in Settings, and never
/// sooner than an hour after an attempt that failed. Nothing about the
/// library is sent: the chart is fetched whole and matched on this Mac.
final class PopularStore {
    static let shared = PopularStore()
    static let didChange = Notification.Name("TuberView.Popular.didChange")

    static let refreshAge: TimeInterval = 24 * 3600
    static let retryAge: TimeInterval = 3600
    /// Twenty titles a page.
    static let pages = 8

    /// A title reduced to letters and digits, and its year (0 if unknown).
    struct Entry: Codable {
        var key: String
        var year: Int
    }

    struct Saved: Codable {
        var fetched: Double = 0
        var tried: Double = 0
        var movies: [Entry] = []
        var shows: [Entry] = []
    }

    /// The chart as it stands, most popular first, to be read on any thread.
    struct Chart {
        let movies: [Entry]
        let shows: [Entry]
    }

    private var saved = Saved()
    private var isLoading = false
    private var demo = false
    /// What the last attempt found, in words that are safe to print.
    private(set) var report: [String] = []
    private let work = DispatchQueue(label: "tuberview.popular", qos: .utility)
    private var file: URL { ConfigStore.shared.directory.appendingPathComponent("popular.json") }
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private init() {
        if let data = try? Data(contentsOf: file),
           let read = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = read
        }
    }

    var chart: Chart { Chart(movies: saved.movies, shows: saved.shows) }
    var isBusy: Bool { isLoading }
    var hasKey: Bool { !key.isEmpty }
    var counts: (movies: Int, shows: Int) { (saved.movies.count, saved.shows.count) }

    private var key: String {
        ConfigStore.shared.config.tmdbKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For the pictures taken by the cloud build. Nothing is saved.
    func installDemo(movies: [(String, Int)], shows: [String]) {
        demo = true
        saved.movies = movies.map { Entry(key: Titles.key($0.0), year: $0.1) }
        saved.shows = shows.map { Entry(key: Titles.key($0), year: 0) }
        NotificationCenter.default.post(name: PopularStore.didChange, object: self)
    }

    /// The key in Settings changed: forget the old chart's age and ask again.
    func keyChanged() {
        guard !demo else { return }
        saved.fetched = 0
        saved.tried = 0
        if key.isEmpty {
            saved.movies = []
            saved.shows = []
            save()
            NotificationCenter.default.post(name: PopularStore.didChange, object: self)
        } else {
            refreshIfDue(force: true)
        }
    }

    /// Fetch the chart if it is due.
    func refreshIfDue(force: Bool = false) {
        guard !demo, !isLoading else { return }
        let key = self.key
        guard !key.isEmpty else {
            report = ["no TMDB key in Settings"]
            return
        }
        let now = Date().timeIntervalSince1970
        if now - saved.fetched < PopularStore.refreshAge && saved.fetched <= now { return }
        if !force && now - saved.tried < PopularStore.retryAge && saved.tried <= now { return }
        report = []
        isLoading = true
        saved.tried = now
        save()
        collect(kind: "movie", key: key, page: 1, into: []) { [weak self] films in
            guard let self = self else { return }
            self.collect(kind: "tv", key: key, page: 1, into: []) { shows in
                self.isLoading = false
                self.report.append("chart read: \(films.count) film titles, \(shows.count) show titles")
                guard !films.isEmpty || !shows.isEmpty else { return }
                if !films.isEmpty { self.saved.movies = films }
                if !shows.isEmpty { self.saved.shows = shows }
                if !films.isEmpty && !shows.isEmpty {
                    self.saved.fetched = Date().timeIntervalSince1970
                }
                self.save()
                NotificationCenter.default.post(name: PopularStore.didChange, object: self)
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

    /// Read the chart a page at a time. `done` gets what was read, on the
    /// main thread; a page that fails ends the reading there.
    private func collect(kind: String, key: String, page: Int, into list: [Entry],
                         done: @escaping ([Entry]) -> Void) {
        guard page <= PopularStore.pages else {
            done(list)
            return
        }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.themoviedb.org"
        parts.path = "/3/trending/\(kind)/week"
        var items = [URLQueryItem(name: "page", value: String(page)),
                     URLQueryItem(name: "language", value: "en-US")]
        // a long key is the newer kind, sent as a header; a short one goes
        // in the address
        let bearer = key.count > 60
        if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        parts.queryItems = items
        guard let url = parts.url else {
            done(list)
            return
        }
        var ask = URLRequest(url: url)
        ask.setValue("application/json", forHTTPHeaderField: "Accept")
        if bearer { ask.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let task = session.dataTask(with: ask) { [work] data, response, error in
            work.async {
                var found: [Entry] = []
                var note: String?
                if let error = error {
                    note = "\(kind) chart page \(page): failed, error \((error as NSError).domain) \((error as NSError).code)"
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status == 401 {
                        note = "\(kind) chart: TMDB did not accept the key"
                    } else if !(200..<300).contains(status) {
                        note = "\(kind) chart page \(page): answer \(status)"
                    } else if let data = data,
                              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              let rows = object["results"] as? [[String: Any]] {
                        for row in rows {
                            let date = (row["release_date"] as? String) ?? (row["first_air_date"] as? String) ?? ""
                            let year = Int(date.prefix(4)) ?? 0
                            for field in ["title", "name", "original_title", "original_name"] {
                                guard let name = row[field] as? String else { continue }
                                let key = Titles.key(name)
                                if !key.isEmpty && !found.contains(where: { $0.key == key && $0.year == year }) {
                                    found.append(Entry(key: key, year: year))
                                }
                            }
                        }
                        if rows.isEmpty { note = "\(kind) chart page \(page): empty" }
                    } else {
                        note = "\(kind) chart page \(page): not readable as data"
                    }
                }
                DispatchQueue.main.async {
                    if let note = note {
                        self.report.append(note)
                        done(list)
                    } else {
                        self.collect(kind: kind, key: key, page: page + 1, into: list + found, done: done)
                    }
                }
            }
        }
        task.resume()
    }
}
