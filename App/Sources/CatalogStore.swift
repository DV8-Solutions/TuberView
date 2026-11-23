import Foundation
import TuberCore

/// The films and shows of the current playlist, arranged for browsing.
/// Rebuilt in the background whenever the playlist changes. Main thread
/// only.
final class CatalogStore {
    static let shared = CatalogStore()
    static let didChange = Notification.Name("TuberView.Catalog.didChange")

    private(set) var catalog = Catalog()
    /// The playlist the catalog was built from; its positions index this.
    private(set) var channels: [Channel] = []
    private(set) var revision = -1
    private(set) var isBuilding = false
    private var wanted = -1
    private let work = DispatchQueue(label: "tuberview.catalog", qos: .userInitiated)
    private let ticket = SearchTicket()

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: Library.didChange, object: nil)
        libraryChanged()
    }

    @objc private func libraryChanged() {
        let library = Library.shared
        guard library.revision != wanted else { return }
        wanted = library.revision
        let list = library.channels
        let revision = library.revision
        let ticket = self.ticket
        let mine = ticket.next()
        isBuilding = true
        work.async {
            let built = Catalog.build(from: list, cancelled: { ticket.current != mine })
            DispatchQueue.main.async {
                guard ticket.current == mine, let built = built else { return }
                self.catalog = built
                self.channels = list
                self.revision = revision
                self.isBuilding = false
                NotificationCenter.default.post(name: CatalogStore.didChange, object: self)
            }
        }
    }

    /// The playlist entry with this address, if it is still there.
    func channel(url: String) -> Channel? {
        guard let i = catalog.position[url], i < channels.count else { return nil }
        return channels[i]
    }

    func channel(at position: Int) -> Channel? {
        position >= 0 && position < channels.count ? channels[position] : nil
    }
}

/// What was watched most recently, for "Continue watching".
final class Recents {
    static let shared = Recents()
    static let didChange = Notification.Name("TuberView.Recents.didChange")

    struct Entry: Codable, Equatable {
        var url: String
        var positionMs: Int
        var lengthMs: Int
        var at: Double
    }

    private let file = JSONFile<[Entry]>(name: "recent.json", empty: [])

    private init() {}

    var entries: [Entry] { file.value }

    /// Remember how far a film or an episode got. Newest first.
    func note(url: String, positionMs: Int, lengthMs: Int) {
        var list = file.value.filter { $0.url != url }
        if Resume.positionToSave(positionMs: positionMs, lengthMs: lengthMs) != nil {
            list.insert(Entry(url: url, positionMs: positionMs, lengthMs: lengthMs,
                              at: Date().timeIntervalSince1970), at: 0)
        }
        if list.count > 40 { list.removeLast(list.count - 40) }
        guard list != file.value else { return }
        file.value = list
        file.saveSoon()
        NotificationCenter.default.post(name: Recents.didChange, object: self)
    }

    func forget(url: String) {
        guard file.value.contains(where: { $0.url == url }) else { return }
        file.value = file.value.filter { $0.url != url }
        file.saveSoon()
        NotificationCenter.default.post(name: Recents.didChange, object: self)
    }

    func flush() { file.flush() }
}
