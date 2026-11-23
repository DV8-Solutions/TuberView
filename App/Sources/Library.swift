import Foundation
import TuberCore

/// The channel list: where it comes from and when it was last fetched.
///
/// On launch the copy saved last time is shown straight away, then a fresh
/// one is downloaded and swapped in. Everything published here happens on the
/// main thread.
final class Library {
    static let shared = Library()
    static let didChange = Notification.Name("TuberView.Library.didChange")

    private(set) var channels: [Channel] = []
    /// Goes up every time `channels` is replaced.
    private(set) var revision = 0
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// Goes up with every download, so an answer to an older request - for a
    /// source that has since been changed - is ignored when it arrives.
    private var requestID = 0

    var hasSource: Bool {
        !ConfigStore.shared.config.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let work = DispatchQueue(label: "tuberview.library", qos: .userInitiated)
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Providers commonly refuse anything that does not look like a player.
        c.httpAdditionalHeaders = ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
        return URLSession(configuration: c)
    }()

    private init() {}

    /// Show the saved list, then fetch a fresh one.
    /// On opening, a saved list younger than this is used as it is.
    static let openRefreshAge: TimeInterval = 6 * 3600

    func start() {
        let cache = ConfigStore.shared.playlistCache
        work.async {
            var saved: [Channel]?
            if let data = try? Data(contentsOf: cache), M3U.looksLikePlaylist(data) {
                saved = M3U.parse(data)
            }
            DispatchQueue.main.async {
                if let saved = saved, !saved.isEmpty, self.channels.isEmpty {
                    self.install(saved)
                }
                // Downloading the playlist counts as a connection on the
                // provider's side, so opening the app does not fetch a list
                // it already has a recent copy of. Refresh Channels always
                // fetches.
                let age = Date().timeIntervalSince1970 - ConfigStore.shared.config.lastRefresh
                if self.channels.isEmpty || age < 0 || age > Library.openRefreshAge {
                    self.refresh()
                } else {
                    self.announce()
                }
            }
        }
    }

    /// Download the playlist again. Safe to call at any time; a second call
    /// while one is running does nothing.
    func refresh() {
        let source = ConfigStore.shared.config.source
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            lastError = nil
            announce()
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        requestID += 1
        let request = requestID
        announce()

        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = Library.webURL(from: source) else {
                finishOnMain(request: request, parsed: nil,
                             message: "That playlist link isn't a valid web address.")
                return
            }
            let task = session.dataTask(with: URLRequest(url: url)) { data, response, error in
                self.work.async {
                    self.digest(request: request, data: data, response: response,
                                error: error, remote: true)
                }
            }
            task.resume()
        } else {
            let path: String
            if lower.hasPrefix("file://"), let url = URL(string: source) {
                path = url.path
            } else {
                path = (source as NSString).expandingTildeInPath
            }
            work.async {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    self.digest(request: request, data: data, response: nil, error: nil, remote: false)
                } catch {
                    self.digest(request: request, data: nil, response: nil, error: error, remote: false)
                }
            }
        }
    }

    /// For the pictures taken by the cloud build: a made-up list, never
    /// saved and never fetched.
    func installDemo(_ list: [Channel]) {
        requestID += 1
        isRefreshing = false
        lastError = nil
        install(list)
    }

    /// Forget the list, for when the source is changed to something else.
    func clear() {
        requestID += 1          // whatever is still downloading no longer counts
        isRefreshing = false
        let cache = ConfigStore.shared.playlistCache
        // on the same queue as the saves, so the two cannot cross
        work.async { try? FileManager.default.removeItem(at: cache) }
        channels = []
        revision += 1
        lastError = nil
        announce()
    }

    // MARK: - Private

    /// Runs on the work queue.
    private func digest(request: Int, data: Data?, response: URLResponse?,
                        error: Error?, remote: Bool) {
        var message: String?
        var parsed: [Channel]?
        var toSave: Data?

        if let error = error {
            message = Library.describe(error, remote: remote)
        } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            message = "Your provider answered with error \(http.statusCode). The channel list was not changed."
        } else if let data = data, M3U.looksLikePlaylist(data) {
            let list = M3U.parse(data)
            if list.isEmpty {
                message = "The playlist came back empty. The channel list was not changed."
            } else {
                parsed = list
                if remote { toSave = data }
            }
        } else {
            message = "That address did not return a playlist. The channel list was not changed."
        }

        DispatchQueue.main.async {
            self.finishOnMain(request: request, parsed: parsed, message: message, toSave: toSave)
        }
    }

    private func finishOnMain(request: Int, parsed: [Channel]?, message: String?,
                              toSave: Data? = nil) {
        guard request == requestID else { return }
        isRefreshing = false
        if let toSave = toSave {
            // Kept for next launch, so the list is on screen before the
            // fresh download finishes.
            let cache = ConfigStore.shared.playlistCache
            work.async {
                try? toSave.write(to: cache, options: .atomic)
                ConfigStore.lock(cache)
            }
        }
        if let parsed = parsed {
            lastError = nil
            ConfigStore.shared.update { $0.lastRefresh = Date().timeIntervalSince1970 }
            install(parsed)
        } else {
            lastError = message
            announce()
        }
    }

    private func install(_ list: [Channel]) {
        channels = list
        revision += 1
        announce()
    }

    private func announce() {
        NotificationCenter.default.post(name: Library.didChange, object: self)
    }

    /// Never includes the address: it carries the account login.
    private static func describe(_ error: Error, remote: Bool) -> String {
        guard remote else { return "That playlist file couldn't be read." }
        let fallback = "The channel list couldn't be refreshed. The one you have was kept."
        guard let code = (error as? URLError)?.code else { return fallback }
        if code == .notConnectedToInternet || code == .networkConnectionLost
            || code == .dataNotAllowed {
            return "This Mac is offline, so the channel list was not refreshed."
        }
        if code == .timedOut {
            return "Your provider took too long to answer. The channel list was not changed."
        }
        if code == .cannotFindHost || code == .dnsLookupFailed || code == .cannotConnectToHost {
            return "Your provider couldn't be reached. The channel list was not changed."
        }
        return fallback
    }

    static func webURL(from text: String) -> URL? {
        if let url = URL(string: text), url.host != nil { return url }
        if let escaped = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: escaped), url.host != nil {
            return url
        }
        return nil
    }
}
