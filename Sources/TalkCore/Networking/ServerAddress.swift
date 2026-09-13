import Foundation

/// A validated, normalized Nextcloud base address.
///
/// Users paste all sorts of things into the server field — a bare host, a URL copied
/// out of the browser while Talk was open, a trailing slash, a `/index.php/...` path.
/// Normalization happens once, here, and is tested.
struct ServerAddress: Sendable, Hashable, Codable {
    /// Normalized: scheme + host (+ port) (+ installation subdirectory), never a trailing slash.
    let url: URL

    var host: String { url.host() ?? url.absoluteString }
    var displayString: String {
        var text = url.absoluteString
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        return text
    }

    private init(validated url: URL) {
        self.url = url
    }

    /// - Parameter allowInsecureHTTP: only ever true behind the developer-mode flag,
    ///   and even then only for addresses that are plainly local (see ``isLocalHost``).
    static func parse(_ input: String, allowInsecureHTTP: Bool = false) throws(TalkError) -> ServerAddress {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .invalidServerURL(input) }

        // A bare host: assume HTTPS rather than making the user type it.
        if !text.contains("://") { text = "https://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw .invalidServerURL(input) }

        guard scheme == "https" || scheme == "http" else { throw .invalidServerURL(input) }
        if scheme == "http" {
            guard allowInsecureHTTP, isLocalHost(host) else { throw .insecureServer(host: host) }
        }

        // Drop anything the user pasted from inside the web UI. Nextcloud can live in a
        // subdirectory, so only the parts that are unambiguously app routes are removed.
        var path = components.path
        if let range = path.range(of: "/index.php") { path = String(path[path.startIndex..<range.lowerBound]) }
        if let range = path.range(of: "/apps/") { path = String(path[path.startIndex..<range.lowerBound]) }
        if let range = path.range(of: "/ocs/") { path = String(path[path.startIndex..<range.lowerBound]) }
        if let range = path.range(of: "/remote.php") { path = String(path[path.startIndex..<range.lowerBound]) }
        while path.hasSuffix("/") { path.removeLast() }

        components.scheme = scheme
        components.path = path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil

        guard let url = components.url else { throw .invalidServerURL(input) }
        return ServerAddress(validated: url)
    }

    /// Loopback and RFC1918/`.local` addresses — the only places plain HTTP is ever tolerated.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".test") { return true }
        if host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    /// Builds an absolute URL for a server-relative path, preserving any installation subdirectory.
    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = components.path
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = base + suffix
        components.queryItems = query.isEmpty ? nil : query
        // Safe: both halves came from already-valid components.
        return components.url ?? url
    }
}
