import Foundation

/// Server-side message search.
///
/// Talk does not expose a search endpoint of its own; it registers providers with
/// Nextcloud's unified search, and the client asks core for a named provider's results.
/// Two providers matter here:
///
/// - `talk-message` — messages across every conversation the user is in. Given the
///   `conversation` filter it searches exactly one instead.
/// - `talk-conversations` — conversations by name, which the app does locally and does not
///   need from the server.
///
/// Whether the provider exists at all is answered by asking the server, not by a version
/// check: `/search/providers` lists what this installation actually has, which also covers
/// an administrator having disabled it.
actor MessageSearchService {
    /// Talk's message search provider, from `MessageSearch::getId()`.
    static let messageProviderID = "talk-message"
    /// Its one custom filter, from `MessageSearch::CONVERSATION_FILTER`.
    static let conversationFilter = "conversation"

    private let client: OCSClient
    /// Cached for the session: providers change when apps are enabled, not between
    /// keystrokes. `nil` means "not asked yet".
    private var availableProviders: Set<String>?

    init(client: OCSClient) {
        self.client = client
    }

    /// Whether this server offers Talk message search.
    ///
    /// Failure is reported as "no": search is an enhancement, and an unreachable server
    /// will make itself known through the requests that matter.
    func isAvailable() async -> Bool {
        if let availableProviders {
            return availableProviders.contains(Self.messageProviderID)
        }
        do throws(TalkError) {
            let response = try await client.send(
                OCSRequest.get(Endpoint.searchProviders),
                as: [UnifiedSearchProviderDTO].self
            )
            let ids = Set((response.value ?? []).map(\.id))
            availableProviders = ids
            return ids.contains(Self.messageProviderID)
        } catch {
            Log.api.debug("Couldn’t list search providers: \(error.userMessage)")
            return false
        }
    }

    /// One page of results.
    ///
    /// - Parameters:
    ///   - term: what to look for. An empty term returns nothing rather than everything.
    ///   - token: restrict to one conversation. `nil` searches all of them.
    ///   - cursor: the `cursor` from the previous page, echoed back unchanged.
    func searchMessages(
        term: String,
        in token: String? = nil,
        cursor: String? = nil,
        limit: Int = 25
    ) async throws(TalkError) -> MessageSearchPage {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var query = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        // Filters are ordinary query parameters: core builds the filter list for the
        // provider out of the whole request, so a custom filter is just its own name.
        if let token, !token.isEmpty {
            query.append(URLQueryItem(name: Self.conversationFilter, value: token))
        }

        let response = try await client.send(
            OCSRequest.get(Endpoint.searchProvider(Self.messageProviderID), query: query),
            as: UnifiedSearchResultDTO.self
        )
        guard let result = response.value else { return .empty }

        return MessageSearchPage(
            // An entry we can't navigate to is worse than no entry, so `hit()` drops it.
            hits: result.entries.compactMap { $0.hit() },
            cursor: result.cursor,
            isPaginated: result.isPaginated
        )
    }
}
