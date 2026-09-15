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
    ///
    /// Matched by parsing rather than by string prefix. `10.evil.example` and
    /// `192.168.evil.example` are registrable public domains, and a prefix test hands them
    /// the one exemption in the app that allows cleartext credentials.
    static func isLocalHost(_ host: String) -> Bool {
        var host = host.lowercased()
        // A URL carries an IPv6 literal in brackets; compare the address itself.
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty else { return false }

        if let octets = ipv4Octets(host) {
            if octets[0] == 127 { return true }                              // 127.0.0.0/8
            if octets[0] == 10 { return true }                               // 10.0.0.0/8
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }  // 172.16.0.0/12
            if octets[0] == 192, octets[1] == 168 { return true }            // 192.168.0.0/16
            return false
        }

        if host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // mDNS. `.test` is only a reserved name, not a local network, so it is not here.
        return host.hasSuffix(".local")
    }

    /// The four octets of a dotted-quad IPv4 literal, or `nil` for anything else — including
    /// a hostname that merely starts with digits.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Builds an absolute URL for a server-relative path, preserving any installation subdirectory.
    ///
    /// `path` is a **decoded** path: `URLComponents` performs the single percent-encoding
    /// step on the way out, so callers must never pre-encode. ``Endpoint`` is written to
    /// that convention — encoding twice is how `café.pdf` became `caf%25C3%25A9.pdf`.
    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let base = components.path
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = base + suffix
        components.queryItems = query.isEmpty ? nil : query
        guard let built = components.url else {
            // Returning the server root here is how a DELETE aimed at one resource becomes a
            // DELETE of another, method, body and Authorization header intact. Hand back an
            // address nothing can dial instead, so the caller gets a failure it can report.
            Log.api.error("Couldn’t build a URL for a server path; the request cannot be sent")
            return Self.unroutable
        }
        return built
    }

    /// Stands in for a URL that could not be built. Its scheme has no handler, so a request
    /// carrying it fails at the transport rather than arriving anywhere.
    static let unroutable = URL(string: "kvidr-unroutable:///")!
}
