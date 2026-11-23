import Foundation

/// What the app remembers between launches.
struct Config: Codable, Equatable {
    /// The playlist: a web link from the provider, or a path to an .m3u file.
    /// It carries the account login, so it lives only in this file on this Mac.
    var source = ""
    var guideURL = ""
    var volume = 80
    var muted = false
    var lastRefresh: Double = 0
    /// How many streams the provider's plan allows at once. The app never
    /// opens more than this.
    var maxStreams = 2
    /// Where recordings go. Empty means the TuberView folder in Movies.
    var recordingsFolder = ""
    /// Hours to move the guide's times by, when a guide publishes them
    /// wrongly. Nil means TuberView decides: see `GuideStore.shiftHours`.
    var guideShiftHours: Int?
    /// The user's own key for TMDB's popularity chart, which picks the
    /// Top 10 rows. Empty means the rows go by the provider's ratings.
    var tmdbKey = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        guideURL = try c.decodeIfPresent(String.self, forKey: .guideURL) ?? ""
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? 80
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        lastRefresh = try c.decodeIfPresent(Double.self, forKey: .lastRefresh) ?? 0
        maxStreams = try c.decodeIfPresent(Int.self, forKey: .maxStreams) ?? 2
        recordingsFolder = try c.decodeIfPresent(String.self, forKey: .recordingsFolder) ?? ""
        guideShiftHours = try c.decodeIfPresent(Int.self, forKey: .guideShiftHours)
        tmdbKey = try c.decodeIfPresent(String.self, forKey: .tmdbKey) ?? ""
    }
}

/// Reads and writes `~/Library/Application Support/TuberView/config.json`.
/// Main thread only.
final class ConfigStore {
    static let shared = ConfigStore()

    let directory: URL
    private(set) var config = Config()
    private var pendingSave: DispatchWorkItem?

    var playlistCache: URL { directory.appendingPathComponent("playlist.m3u") }
    private var file: URL { directory.appendingPathComponent("config.json") }

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("TuberView", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Config.self, from: data) {
            config = saved
        }
    }

    /// Change something. The file is written shortly afterwards, so dragging
    /// the volume does not write a hundred times.
    func update(_ change: (inout Config) -> Void) {
        let before = config
        change(&config)
        guard config != before else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Write now. Called on quit.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: file, options: .atomic)
        ConfigStore.lock(file)
    }

    /// Only this user may read the file: it holds the provider login.
    static func lock(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
