import Foundation
import TuberCore

/// What is on now and next, from the provider's guide.
///
/// The guide file is large, so it is downloaded at most twice a day, kept on
/// disk, and read in the background. Only the next day or so is held in
/// memory. Main thread only, apart from the reading itself.
final class GuideStore {
    static let shared = GuideStore()
    static let didChange = Notification.Name("TuberView.Guide.didChange")

    /// A saved guide younger than this is not downloaded again.
    static let refreshAge: TimeInterval = 12 * 3600

    private(set) var isLoading = false
    private var guide = XMLTV.Guide()
    private var shows: [String: [Programme]] { guide.shows }
    /// Which guide channel each playlist entry turned out to be. Working
    /// it out takes a moment, and a list on screen asks again and again.
    private var resolved: [String: String] = [:]
    private var loadedAt: TimeInterval = 0
    private var requestID = 0
    private var readID = 0
    private let work = DispatchQueue(label: "tuberview.guide", qos: .utility)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private var file: URL { ConfigStore.shared.directory.appendingPathComponent("guide.xml") }

    private init() {}

    var hasGuide: Bool { !shows.isEmpty }

    /// Hours the guide's times are moved by before they are shown. It can
    /// be set in Settings. Left alone, it is 0, except for the one
    /// public guide known to publish every time eight hours late (its times
    /// are China's clock labelled as universal time).
    var shiftHours: Int {
        let config = ConfigStore.shared.config
        if let chosen = config.guideShiftHours { return max(-12, min(12, chosen)) }
        let host = URL(string: config.guideURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host
        return host?.lowercased() == "epg.pw" ? -8 : 0
    }

    private var shift: TimeInterval { TimeInterval(shiftHours) * 3600 }

    /// The time shift was changed in Settings.
    func shiftChanged() {
        NotificationCenter.default.post(name: GuideStore.didChange, object: self)
    }

    /// For the self tests: how many guide channels have shows, and how
    /// many names they answer to.
    var size: (channels: Int, names: Int) { (shows.count, guide.aliases.count) }

    /// Read the saved guide, then fetch a newer one if it is due.
    func start() {
        let fm = FileManager.default
        let saved = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        if let saved = saved {
            read()
            if Date().timeIntervalSince(saved) < GuideStore.refreshAge { return }
        }
        refresh()
    }

    /// Download the guide again.
    func refresh() {
        let text = ConfigStore.shared.config.guideURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let url = URL(string: text) else { return }
        guard !isLoading else { return }
        isLoading = true
        requestID += 1
        let request = requestID
        let target = file
        let task = session.downloadTask(with: url) { [weak self] temp, response, _ in
            var ok = false
            if let temp = temp, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let fm = FileManager.default
                let staged = target.appendingPathExtension("new")
                try? fm.removeItem(at: staged)
                if (try? fm.moveItem(at: temp, to: staged)) != nil {
                    // a web page with an error on it is not a guide
                    let head = (try? FileHandle(forReadingFrom: staged))?.readData(ofLength: 2048) ?? Data()
                    if String(decoding: head, as: UTF8.self).contains("<tv") {
                        try? fm.removeItem(at: target)
                        ok = (try? fm.moveItem(at: staged, to: target)) != nil
                    } else {
                        try? fm.removeItem(at: staged)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self = self, request == self.requestID else { return }
                self.isLoading = false
                if ok { self.read() }
            }
        }
        task.resume()
    }

    /// Forget everything, for when the guide link is changed.
    func clear() {
        requestID += 1
        readID += 1
        isLoading = false
        guide = XMLTV.Guide()
        resolved = [:]
        try? FileManager.default.removeItem(at: file)
        NotificationCenter.default.post(name: GuideStore.didChange, object: self)
    }

    private func read() {
        readID += 1
        let request = readID
        let source = file
        let now = Date().timeIntervalSince1970
        work.async {
            guard let stream = InputStream(url: source) else { return }
            // A little of the past, so a show that has started is still
            // found, and half a day more each way so the times can be
            // shifted without reading the file again.
            let found = XMLTV.read(stream: stream, from: now - 18 * 3600, to: now + 48 * 3600)
            DispatchQueue.main.async {
                guard request == self.readID else { return }
                self.guide = found
                self.resolved = [:]
                self.loadedAt = now
                NotificationCenter.default.post(name: GuideStore.didChange, object: self)
            }
        }
    }

    /// What is on this channel now and next. Empty when the guide has
    /// nothing for it.
    func nowAndNext(guideID: String, name: String) -> (now: Programme?, next: Programme?) {
        guard let list = listing(guideID: guideID, name: name) else { return (nil, nil) }
        // the list holds the times as published; `shift` corrects them
        let pair = XMLTV.nowAndNext(in: list, at: Date().timeIntervalSince1970 - shift)
        func moved(_ show: Programme?) -> Programme? {
            guard let show = show else { return nil }
            return Programme(start: show.start + shift, stop: show.stop + shift,
                             title: GuideStore.plain(show.title))
        }
        return (moved(pair.now), moved(pair.next))
    }

    /// Every show on this channel that overlaps the given span, in order,
    /// with corrected times. Empty when the guide has nothing for it.
    func programmes(guideID: String, name: String, from: TimeInterval, to: TimeInterval) -> [Programme] {
        guard let list = listing(guideID: guideID, name: name) else { return [] }
        var out: [Programme] = []
        for show in list {
            let start = show.start + shift
            let stop = show.stop + shift
            if start >= to { break }
            if stop > from && stop > start {
                out.append(Programme(start: start, stop: stop, title: GuideStore.plain(show.title)))
            }
        }
        return out
    }

    /// Some guides escape their titles twice, leaving "&amp;" in the text.
    static func plain(_ title: String) -> String {
        guard title.contains("&") else { return title }
        return title.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private func listing(guideID: String, name: String) -> [Programme]? {
        guard hasGuide else { return nil }
        let key = guideID + "\u{1}" + name
        let id: String
        if let known = resolved[key] {
            id = known
        } else {
            id = guide.channel(guideID: guideID, name: name) ?? ""
            resolved[key] = id
        }
        guard !id.isEmpty else { return nil }
        return shows[id]
    }

    /// For the pictures taken by the cloud build.
    func installDemo(_ demo: XMLTV.Guide) {
        requestID += 1
        readID += 1
        guide = demo
        resolved = [:]
        NotificationCenter.default.post(name: GuideStore.didChange, object: self)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "SportsCenter until 3:00 PM", or nil when nothing is known.
    func line(guideID: String, name: String) -> String? {
        let pair = nowAndNext(guideID: guideID, name: name)
        if let now = pair.now {
            let until = GuideStore.clock.string(from: Date(timeIntervalSince1970: now.stop))
            return "\(now.title) until \(until)"
        }
        if let next = pair.next {
            let at = GuideStore.clock.string(from: Date(timeIntervalSince1970: next.start))
            return "\(at) \(next.title)"
        }
        return nil
    }

    /// "Next: 3:00 PM NFL Live", or nil.
    func nextLine(guideID: String, name: String) -> String? {
        guard let next = nowAndNext(guideID: guideID, name: name).next else { return nil }
        let at = GuideStore.clock.string(from: Date(timeIntervalSince1970: next.start))
        return "Next: \(at) \(next.title)"
    }
}
