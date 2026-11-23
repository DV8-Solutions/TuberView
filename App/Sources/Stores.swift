import Foundation
import TuberCore

/// A small JSON file in the app's folder, written a moment after a change.
/// Main thread only.
final class JSONFile<Value: Codable> {
    private let url: URL
    private var pending: DispatchWorkItem?
    private var dirty = false
    var value: Value {
        didSet { dirty = true }
    }

    init(name: String, empty: Value) {
        url = ConfigStore.shared.directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(Value.self, from: data) {
            value = saved
        } else {
            value = empty
        }
    }

    func saveSoon() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        ConfigStore.lock(url)
    }
}

/// Starred entries, remembered by address so they survive a playlist refresh.
final class Favorites {
    static let shared = Favorites()
    static let didChange = Notification.Name("TuberView.Favorites.didChange")

    private let file = JSONFile<[String]>(name: "favorites.json", empty: [])
    private(set) var urls: Set<String>

    private init() {
        urls = Set(file.value)
    }

    func contains(_ channel: Channel) -> Bool {
        urls.contains(channel.url)
    }

    func toggle(_ channel: Channel) {
        if urls.contains(channel.url) {
            urls.remove(channel.url)
        } else {
            urls.insert(channel.url)
        }
        file.value = urls.sorted()
        file.saveSoon()
        NotificationCenter.default.post(name: Favorites.didChange, object: self)
    }

    /// Add several at once, for adding a batch of favorites in one go.
    func add(urls more: [String]) {
        let before = urls.count
        urls.formUnion(more)
        guard urls.count != before else { return }
        file.value = urls.sorted()
        file.saveSoon()
        NotificationCenter.default.post(name: Favorites.didChange, object: self)
    }

    func flush() { file.flush() }
}

/// Where each film and episode was left, in milliseconds, by address.
final class ResumePoints {
    static let shared = ResumePoints()

    private let file = JSONFile<[String: Int]>(name: "resume.json", empty: [:])

    private init() {}

    func position(for url: String) -> Int {
        file.value[url] ?? 0
    }

    /// Record where playback got to, or forget it when it is not worth keeping.
    func record(url: String, positionMs: Int, lengthMs: Int) {
        let keep = Resume.positionToSave(positionMs: positionMs, lengthMs: lengthMs)
        if file.value[url] == keep { return }
        file.value[url] = keep
        file.saveSoon()
    }

    /// Set a place directly, unless one is already remembered.
    func adopt(url: String, positionMs: Int) {
        guard positionMs >= 30_000, file.value[url] == nil else { return }
        file.value[url] = positionMs
        file.saveSoon()
    }

    func forget(url: String) {
        guard file.value[url] != nil else { return }
        file.value[url] = nil
        file.saveSoon()
    }

    func flush() { file.flush() }
}

/// Where recordings are kept and what they are called.
enum Recordings {

    /// The folder recordings go to, made if it is not there yet.
    static var folder: URL {
        let url = location
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where recordings go, whether or not the folder exists yet.
    static var location: URL {
        let chosen = ConfigStore.shared.config.recordingsFolder
        let url: URL
        if chosen.isEmpty {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
            url = movies.appendingPathComponent("TuberView", isDirectory: true)
        } else {
            url = URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath, isDirectory: true)
        }
        return url
    }

    /// A name for a recording of this channel starting now:
    /// "ESPN HD 2026-11-22 14.30.05".
    static func newName(title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()&+"))
        var name = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        name = name.split(separator: " ").joined(separator: " ")
        if name.isEmpty { name = "Recording" }
        if name.count > 80 { name = String(name.prefix(80)) }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(name) \(stamp.string(from: Date()))"
    }

    // While a recording runs its files sit in a hidden folder beside the
    // finished ones, under whatever names the engine gives them. When it
    // ends they move out under the recording's own name.

    private static let stageEnding = ".recording"
    private static var active: Set<String> = []

    /// The hidden folder a new recording of this channel writes into.
    static func newStage(title: String) -> URL {
        folder.appendingPathComponent("." + newName(title: title) + stageEnding, isDirectory: true)
    }

    static func begin(_ stage: URL) {
        active.insert(stage.path)
    }

    /// The recording is over. Its files are renamed now, which is safe even
    /// while the last one is still being closed, and once more a moment
    /// later in case one appeared late.
    static func finish(_ stage: URL) {
        active.remove(stage.path)
        collect(stage)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if !active.contains(stage.path) { collect(stage) }
        }
    }

    /// Recordings left in their hidden folders by a quit or a crash.
    static func collectLeftovers() {
        let fm = FileManager.default
        let here = location
        guard let entries = try? fm.contentsOfDirectory(atPath: here.path) else { return }
        for entry in entries where entry.hasPrefix(".") && entry.hasSuffix(stageEnding) {
            let stage = here.appendingPathComponent(entry, isDirectory: true)
            if !active.contains(stage.path) { collect(stage) }
        }
    }

    /// Move a recording's files out of its hidden folder: "Name.ts", then
    /// "Name part 2.ts" and so on if the connection had to be reopened.
    @discardableResult
    static func collect(_ stage: URL) -> [URL] {
        let fm = FileManager.default
        let parent = stage.deletingLastPathComponent()
        var base = stage.lastPathComponent
        if base.hasPrefix(".") { base.removeFirst() }
        if base.hasSuffix(stageEnding) { base.removeLast(stageEnding.count) }
        guard let found = try? fm.contentsOfDirectory(atPath: stage.path) else { return [] }
        var moved: [URL] = []
        var part = 1
        for file in found.sorted() where !file.hasPrefix(".") {
            let from = stage.appendingPathComponent(file)
            let size = (try? fm.attributesOfItem(atPath: from.path)[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 {
                try? fm.removeItem(at: from)
                continue
            }
            let ending = (file as NSString).pathExtension.isEmpty ? "ts" : (file as NSString).pathExtension
            var target: URL
            repeat {
                let name = part == 1 ? base : "\(base) part \(part)"
                target = parent.appendingPathComponent(name + "." + ending)
                part += 1
            } while fm.fileExists(atPath: target.path)
            if (try? fm.moveItem(at: from, to: target)) != nil { moved.append(target) }
        }
        if ((try? fm.contentsOfDirectory(atPath: stage.path)) ?? []).isEmpty {
            try? fm.removeItem(at: stage)
        }
        return moved
    }
}
