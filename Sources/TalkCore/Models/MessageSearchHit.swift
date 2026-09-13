import Foundation

/// One message returned by the server's search.
///
/// The unified search API is deliberately presentation-shaped — it exists to fill a
/// drop-down in the web UI — so a hit carries a rendered `title` and `snippet` rather than
/// a `Message`. Talk attaches the parts a client actually needs (which conversation, which
/// message, who, when) as entry attributes; those are what make a hit navigable.
struct MessageSearchHit: Sendable, Hashable, Identifiable {
    var token: String
    var messageID: Int
    var threadID: Int?
    var actorType: String
    var actorID: String
    /// "{user} in {conversation}", already localized and substituted by the server.
    var title: String
    /// The message, cut down to the part around the match — with an ellipsis where the
    /// server trimmed it.
    var snippet: String
    var timestamp: Date
    /// The author's avatar, absolute. Empty for guests.
    var avatarURL: URL?
    /// Where the web UI would send you. The fallback when the message is too far back to
    /// reach by paging.
    var resourceURL: URL?

    var id: String { "\(token)#\(messageID)" }
}

/// A page of hits.
///
/// `cursor` is passed back verbatim: Talk's provider makes it an offset, but the API
/// permits a string, and a client that reinterprets it will break on a provider that does
/// something else.
struct MessageSearchPage: Sendable, Equatable {
    var hits: [MessageSearchHit]
    var cursor: String?
    var isPaginated: Bool

    var hasMore: Bool { isPaginated && cursor != nil && !hits.isEmpty }

    static let empty = MessageSearchPage(hits: [], cursor: nil, isPaginated: false)
}
