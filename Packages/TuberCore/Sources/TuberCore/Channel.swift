import Foundation

/// What a playlist line is, judged from its address.
public enum ChannelKind: String, Codable, Sendable {
    case live
    case movie
    case episode
}

/// One line of the playlist. Every line becomes exactly one of these: nothing
/// is merged, de-duplicated or dropped, so the count the app shows is the
/// count the provider sent.
public struct Channel: Equatable, Sendable {
    /// Position in the playlist, starting at 0.
    public let index: Int
    public let name: String
    public let group: String
    public let logo: String
    public let guideID: String
    public let url: String
    public let kind: ChannelKind
    /// The name in lower case with accents removed, for searching.
    public let folded: String

    public init(index: Int, name: String, group: String, logo: String,
                guideID: String, url: String, kind: ChannelKind) {
        self.index = index
        self.name = name
        self.group = group
        self.logo = logo
        self.guideID = guideID
        self.url = url
        self.kind = kind
        self.folded = Search.fold(name)
    }
}
