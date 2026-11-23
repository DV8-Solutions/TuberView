import Foundation

/// Finding channels by name.
public enum Search {

    /// Lower case, no accents, so "Télé" is found by typing "tele".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words of a query. Every word has to appear in a name for it to match.
    public static func words(_ query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    /// The positions, in playlist order, of every channel that matches.
    ///
    /// - Parameters:
    ///   - kind: only this kind, or every kind when nil.
    ///   - group: only this category, or every category when nil.
    ///   - urls: only entries with one of these addresses (the favorites),
    ///     or every entry when nil.
    ///   - cancelled: asked now and then; returning true abandons the search
    ///     and the result is nil. This is what lets a newer keystroke replace
    ///     an older search instead of racing it.
    public static func matches(in channels: [Channel],
                               query: String,
                               kind: ChannelKind?,
                               group: String? = nil,
                               urls: Set<String>? = nil,
                               cancelled: () -> Bool = { false }) -> [Int]? {
        let wanted = words(query)
        var out: [Int] = []
        if wanted.isEmpty && kind == nil && group == nil && urls == nil {
            return Array(channels.indices)
        }
        out.reserveCapacity(wanted.isEmpty ? channels.count : 256)
        for (i, channel) in channels.enumerated() {
            if i & 0x3FFF == 0 && cancelled() { return nil }
            if let kind = kind, channel.kind != kind { continue }
            if let group = group, channel.group != group { continue }
            if let urls = urls, !urls.contains(channel.url) { continue }
            var hit = true
            for word in wanted where !channel.folded.contains(word) {
                hit = false
                break
            }
            if hit { out.append(i) }
        }
        return out
    }
}

/// A category and how many entries it holds.
public struct GroupCount: Equatable, Sendable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The provider's categories, used only as a way to narrow the list. They
/// never merge or hide anything: an entry is still one row.
public enum Groups {
    /// Categories in the order the playlist first mentions them. Entries
    /// with no category are counted under an empty name.
    public static func list(in channels: [Channel], kind: ChannelKind?) -> [GroupCount] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for channel in channels {
            if let kind = kind, channel.kind != kind { continue }
            if let n = counts[channel.group] {
                counts[channel.group] = n + 1
            } else {
                counts[channel.group] = 1
                order.append(channel.group)
            }
        }
        return order.map { GroupCount(name: $0, count: counts[$0] ?? 0) }
    }
}

/// Where a film or an episode should start when it is opened again.
public enum Resume {
    /// The position worth remembering, or nil when it should be forgotten:
    /// barely started, or close enough to the end to count as finished.
    public static func positionToSave(positionMs: Int, lengthMs: Int) -> Int? {
        if positionMs < 30_000 { return nil }
        if lengthMs > 0 && positionMs > lengthMs - 60_000 { return nil }
        return positionMs
    }
}
