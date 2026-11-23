import AppKit
import TuberCore

/// Takes pictures of the library's pages so its look can be reviewed
/// before a build is handed over: `TuberView --snapshot <folder>`.
///
/// With `--demo` it uses a made-up playlist, guide and ratings and touches
/// nothing real; that is what the cloud build runs. Without it, it shows
/// the real library on this Mac. Either way it opens no channel.
final class Snapshot {
    private let main: MainWindowController
    private let folder: URL
    private var steps = ["live", "movies", "search", "series", "show", "favorites", "recordings", "pick"]
    private var timer: Timer?
    private var settings: SettingsWindowController?

    static var folder: URL? {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--snapshot"), at + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[at + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }

    static var demo: Bool { CommandLine.arguments.contains("--demo") }
    private var screen: Bool { CommandLine.arguments.contains("--screen") }

    init(main: MainWindowController, folder: URL) {
        self.main = main
        self.folder = folder
    }

    private func say(_ text: String) {
        print("SNAPSHOT: \(text)")
        fflush(stdout)
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if Snapshot.demo {
            main.window?.setContentSize(NSSize(width: 1280, height: 800))
            main.window?.center()
        }
        let began = Date()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            let library = Library.shared
            let waited = Date().timeIntervalSince(began)
            let listed = !library.channels.isEmpty && !library.isRefreshing
                && CatalogStore.shared.revision == library.revision
            let guided = GuideStore.shared.hasGuide || waited > 120
            guard (listed && guided) || waited > 240 else { return }
            timer.invalidate()
            self.timer = nil
            let catalog = CatalogStore.shared.catalog
            self.say("channels \(library.channels.count), movies \(catalog.movies.count) in \(catalog.movieGenres.count) genres, series \(catalog.shows.count) in \(catalog.showGenres.count) genres")
            let ratings = RatingsStore.shared.counts
            self.say("ratings: \(ratings.movies) movies, \(ratings.series) series")
            self.next()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func next() {
        if steps.isEmpty && Snapshot.demo && settings == nil {
            // Settings holds the playlist link, so it is only ever pictured
            // with the made-up setup
            let panel = SettingsWindowController()
            settings = panel
            panel.present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if let window = panel.window { self.capture("settings", window: window) }
                panel.close()
                self.next()
            }
            return
        }
        guard !steps.isEmpty else {
            say("DONE")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return
        }
        let name = steps.removeFirst()
        guard main.library.stage(name) else {
            say("\(name): nothing to show")
            next()
            return
        }
        // long enough for artwork to arrive
        let pause: TimeInterval = Snapshot.demo ? 2.0 : 7.0
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            guard let self = self else { return }
            self.capture(name)
            if name == "pick" { self.main.library.pickMessage = nil }
            self.next()
        }
    }

    private func capture(_ name: String) {
        guard let window = main.window else { return }
        capture(name, window: window)
    }

    private func capture(_ name: String, window: NSWindow) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let file = folder.appendingPathComponent("\(name).png")
                try? data.write(to: file)
                say("\(name): \(Int(view.bounds.width)) x \(Int(view.bounds.height))")
            }
        }
        guard screen else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber),
                          folder.appendingPathComponent("\(name)-screen.png").path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            say("\(name): the screen could not be captured")
        }
    }

    // MARK: - Made-up data

    /// A small invented playlist, guide and set of ratings. Nothing here is
    /// saved, fetched or played.
    func installDemo() {
        var list: [Channel] = []
        var guide = XMLTV.Guide()
        var movieRatings: [String: Double] = [:]
        var seriesRatings: [String: Double] = [:]
        func add(_ name: String, _ group: String, _ id: String, _ path: String, _ kind: ChannelKind) {
            list.append(Channel(index: list.count, name: name, group: group, logo: "", guideID: id,
                                url: "http://demo.invalid/\(path)", kind: kind))
        }

        let live: [(String, String, [String])] = [
            ("USA Network", "US Entertainment", ["Law & Order: Special Victims Unit"]),
            ("ESPN", "US Sports", ["College Basketball", "SportsCenter"]),
            ("FOX News", "US News", ["Fox Report With Jon Scott", "Fox News Live"]),
            ("CNN", "US News", ["CNN Newsroom With Fredricka Whitfield", "CNN Newsroom"]),
            ("MS Now", "US News", ["The Assignment With Antonia Hylton", "The Weekend"]),
            ("TNT", "US Entertainment", ["The Polar Express", "FBI"]),
            ("HGTV", "US Entertainment", ["House Hunters"]),
            ("TBS", "US Entertainment", ["Impractical Jokers"]),
            ("Food Network", "US Entertainment", ["Guy's Grocery Games", "Chopped"]),
            ("NFL Network", "US Sports", ["NFL GameDay Live", "NFL Total Access"]),
            ("History", "US Entertainment", ["American Pickers", "Pawn Stars"]),
            ("Local 12 News", "US Locals & Regional", []),
            ("CBC Toronto", "Canada", ["The National", "Marketplace"]),
            ("BBC One", "United Kingdom", ["Antiques Roadshow", "Countryfile"]),
        ]
        let lengths: [Double] = [30, 60, 120, 60, 30, 90]
        let now = Date().timeIntervalSince1970
        let base = (now / 1800).rounded(.down) * 1800 - 3600
        for (i, entry) in live.enumerated() {
            let id = "demo\(i)"
            add("US: \(entry.0) HD", entry.1, id, "live/u/p/\(i).ts", .live)
            guard !entry.2.isEmpty else { continue }
            var shows: [Programme] = []
            var at = base
            var k = i
            while at < now + 8 * 3600 {
                let minutes = lengths[k % lengths.count]
                shows.append(Programme(start: at, stop: at + minutes * 60, title: entry.2[k % entry.2.count]))
                at += minutes * 60
                k += 1
            }
            guide.shows[id] = shows
        }

        let films: [(String, String)] = [
            ("Rambo III 1988", "Action;Adventure"), ("Heat 1995", "Crime;Drama;Thriller"),
            ("The Polar Express 2004", "Animation;Family;Latest Movies"), ("Blade Runner 1982", "Sci-Fi;Thriller"),
            ("The Rainmaker 1997", "Crime;Drama"), ("Up 2009", "Animation;Family;Comedy"),
            ("Apollo 13 1995", "Drama;Adventure"), ("Alien 1979", "Horror;Sci-Fi"),
            ("The Princess Bride 1987", "Adventure;Family;Fantasy"), ("Fargo 1996", "Crime;Thriller;Comedy"),
            ("Casablanca 1942", "Drama;Romance"), ("Jaws 1975", "Thriller;Adventure"),
            ("Spirited Away 2001", "Animation;Fantasy;Family"), ("The Fugitive 1993", "Action;Thriller"),
            ("Groundhog Day 1993", "Comedy;Romance;Fantasy"), ("Gladiator 2000", "Action;Drama;Adventure"),
            ("Paddington 2014", "Family;Comedy;Latest Movies"), ("Arrival 2016", "Sci-Fi;Drama"),
            ("The Thing 1982", "Horror;Sci-Fi"), ("Moonstruck 1987", "Comedy;Romance;Drama"),
        ]
        for round in 0..<3 {
            for (i, film) in films.enumerated() {
                let number = 1000 + round * 100 + i
                let name = round == 0 ? film.0 : film.0.replacingOccurrences(of: " 19", with: " \(round + 1) 19")
                    .replacingOccurrences(of: " 20", with: " \(round + 1) 20")
                add(name, film.1, "", "movie/u/p/\(number).mkv", .movie)
                if (i + round) % 5 != 4 {
                    movieRatings[String(number)] = 5.8 + Double((i * 7 + round * 3) % 30) / 10
                }
            }
        }

        let shows: [(String, String, Int)] = [
            ("Law & Order: Special Victims Unit", "Crime;Drama;TV Crime", 3),
            ("Harry Potter: Wizards of Baking", "Reality;TV Latest Releases", 1),
            ("Hotel Inhumans", "Animation;Action", 1), ("Final Table", "Drama", 2),
            ("As a Reincarnated Aristocrat", "Animation;Fantasy", 1), ("TANK CHAIR", "Animation", 1),
            ("Full Clearing Another World", "Animation;Comedy;TV Latest Releases", 1),
            ("House Hunters", "Reality", 3), ("Impractical Jokers", "Comedy", 3),
            ("FBI", "Crime;Drama", 2), ("The Rainmaker", "Drama", 1), ("The Assignment", "News", 1),
            ("Antiques Roadshow", "Reality;Family", 2), ("The Weekend", "News", 1),
            ("Pawn Stars", "Reality", 2), ("Marketplace", "News;Documentary", 1),
        ]
        var number = 5000
        for (i, show) in shows.enumerated() {
            for season in 1...show.2 {
                for episode in 1...6 {
                    number += 1
                    add(String(format: "%@ S%02dE%02d", show.0, season, episode), show.1, "",
                        "series/u/p/\(number).mp4", .episode)
                }
            }
            if i % 6 != 5 {
                seriesRatings[Titles.key(show.0)] = 6.2 + Double((i * 5) % 25) / 10
            }
        }

        RatingsStore.shared.installDemo(movies: movieRatings, series: seriesRatings)
        PopularStore.shared.installDemo(
            movies: [("Arrival", 2016), ("Heat", 1995), ("Paddington", 2014), ("Gladiator", 2000),
                     ("Jaws", 1975), ("Alien", 1979), ("Up", 2009), ("Fargo", 1996), ("Apollo 13", 1995),
                     ("Spirited Away", 2001), ("Blade Runner", 1982), ("Casablanca", 1942)],
            shows: ["Law & Order: Special Victims Unit", "FBI", "Impractical Jokers", "House Hunters",
                    "Final Table", "The Rainmaker", "Pawn Stars", "Hotel Inhumans", "TANK CHAIR",
                    "Antiques Roadshow", "The Weekend", "Marketplace"])
        GuideStore.shared.installDemo(guide)
        Library.shared.installDemo(list)
    }
}
