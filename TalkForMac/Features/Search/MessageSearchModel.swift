import Foundation
import Observation

/// Searching the server's message history.
///
/// Separate from ``ChatModel``'s find bar on purpose: that one searches what is already on
/// screen and answers instantly, this one asks the server and can reach anything ever
/// said. They are different enough that sharing one text field would make both worse.
@MainActor
@Observable
final class MessageSearchModel: Identifiable {
    /// The sheet is presented by identity, so a new search is a new model.
    nonisolated let id = UUID()

    enum Scope: Hashable, CaseIterable {
        case everywhere
        case thisConversation
    }

    var term = "" {
        didSet {
            guard oldValue != term else { return }
            scheduleSearch()
        }
    }

    var scope: Scope {
        didSet {
            guard oldValue != scope else { return }
            scheduleSearch(immediately: true)
        }
    }

    private(set) var hits: [MessageSearchHit] = []
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    /// Nothing has been asked yet, so "No Results" would be a lie.
    private(set) var hasSearched = false
    private(set) var error: TalkError?
    /// Answered by the server's provider list, not by a version check. Optimistic until
    /// the answer arrives, so the field is never disabled for a frame.
    private(set) var isAvailable = true

    /// Highlighted row, for ↑/↓ and Return.
    var highlighted: Int = 0

    private var cursor: String?
    private var isPaginated = false
    private var searchTask: Task<Void, Never>?
    /// Rises on every search; a response for an older generation is discarded.
    private var generation = 0

    let session: Session
    /// The conversation the window is showing, if any — what "This Conversation" means.
    let currentToken: String?
    let currentConversationName: String?

    init(session: Session, currentToken: String? = nil, currentConversationName: String? = nil) {
        self.session = session
        self.currentToken = currentToken
        self.currentConversationName = currentConversationName
        self.scope = currentToken == nil ? .everywhere : .thisConversation
    }

    var canScopeToConversation: Bool { currentToken != nil }

    var hasMore: Bool { isPaginated && cursor != nil && !hits.isEmpty }

    var scopeToken: String? {
        scope == .thisConversation ? currentToken : nil
    }

    /// Whether to show the empty state rather than a list.
    var showsNoResults: Bool {
        hasSearched && !isSearching && hits.isEmpty && error == nil
            && !term.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func checkAvailability() async {
        isAvailable = await session.messageSearch.isAvailable()
    }

    // MARK: - Searching

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        generation += 1
        let generation = self.generation

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        cursor = nil
        isPaginated = false
        highlighted = 0
        error = nil

        guard !trimmed.isEmpty else {
            hits = []
            hasSearched = false
            isSearching = false
            return
        }

        isSearching = true
        let service = session.messageSearch
        let token = scopeToken

        searchTask = Task { [weak self] in
            if !immediately {
                // A request per keystroke would be one per letter of a name.
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self else { return }

            do throws(TalkError) {
                let page = try await service.searchMessages(term: trimmed, in: token)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.hits = page.hits
                self.cursor = page.cursor
                self.isPaginated = page.isPaginated
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.hits = []
                self.error = error == .cancelled ? nil : error
            }
            self.isSearching = false
            self.hasSearched = true
        }
    }

    /// The next page, appended. Called by the "Show More" button at the end of the list.
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isSearching else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let cursor else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = self.generation

        do throws(TalkError) {
            let page = try await session.messageSearch.searchMessages(
                term: trimmed,
                in: scopeToken,
                cursor: cursor
            )
            guard self.generation == generation else { return }

            // The server pages by offset, so a message sent while the sheet is open can
            // shift the window and repeat a hit. De-duplicate rather than showing it twice.
            let known = Set(hits.map(\.id))
            hits.append(contentsOf: page.hits.filter { !known.contains($0.id) })
            self.cursor = page.cursor
            isPaginated = page.isPaginated
            // A page that was entirely duplicates would otherwise leave a Show More button
            // that does nothing visible.
            if page.hits.isEmpty { self.cursor = nil }
        } catch {
            if error != .cancelled { self.error = error }
        }
    }

    // MARK: - Keyboard

    func move(_ offset: Int) {
        guard !hits.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), hits.count - 1)
    }

    var highlightedHit: MessageSearchHit? {
        hits.indices.contains(highlighted) ? hits[highlighted] : nil
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }
}
