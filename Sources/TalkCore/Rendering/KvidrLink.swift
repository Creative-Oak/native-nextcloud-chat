import Foundation

/// A `kvidr://` link — how Raycast, scripts and other apps point kvidr somewhere. Links open
/// and prefill; they never send or call. A link can come from any web page, and a page
/// shouldn't be able to post in your name or start a call on your camera: sending is for
/// Shortcuts and Siri, which you run yourself.
///
/// - `kvidr://open?conversation=<name or token>`
/// - `kvidr://compose?conversation=<name or token>&text=<words>` — into the field, not sent
/// - `kvidr://catch-up`
/// - `kvidr://search?q=<words>`
enum KvidrLink: Sendable, Equatable {
    case open(conversation: String)
    case compose(conversation: String, text: String)
    case catchUp
    case search(String)

    static let scheme = "kvidr"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        func value(_ names: String...) -> String? {
            for name in names {
                if let found = components.queryItems?.first(where: { $0.name == name })?.value?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty {
                    return found
                }
            }
            return nil
        }
        // kvidr://open?… — the host is the action; kvidr:open?… has it as the path.
        let action = (components.host ?? components.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch action {
        case "open":
            guard let conversation = value("conversation", "token", "name") else { return nil }
            self = .open(conversation: conversation)
        case "compose", "write":
            guard let conversation = value("conversation", "token", "name") else { return nil }
            // Kept as long as a message may be, and no longer.
            self = .compose(conversation: conversation, text: String((value("text", "message") ?? "").prefix(32_000)))
        case "catch-up", "catchup":
            self = .catchUp
        case "search":
            guard let query = value("q", "query") else { return nil }
            self = .search(query)
        default:
            return nil
        }
    }
}
