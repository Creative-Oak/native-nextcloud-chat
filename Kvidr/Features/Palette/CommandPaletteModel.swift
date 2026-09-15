import Foundation
import Observation

/// What the command palette shows for what was typed: conversations and commands at
/// once, people and messages a moment later from the server.
///
/// Sections come in a fixed order and the server's answers only ever *append* — nothing
/// above them moves once it is drawn, so the row under the pointer stays the row under
/// the pointer. The top hit is the best of the local sections alone, for the same reason.
@MainActor
@Observable
final class CommandPaletteModel {
    enum Row: Identifiable {
        case conversation(Conversation)
        case command(AppCommand)
        case person(DirectoryEntry)
        case message(MessageSearchHit)
        case seeAllMessages
        case noResults

        var id: String {
            switch self {
            case .conversation(let c): "conversation:\(c.token)"
            case .command(let c): "command:\(c.id)"
            case .person(let p): "person:\(p.id)"
            case .message(let m): "message:\(m.id)"
            case .seeAllMessages: "messages:all"
            case .noResults: "none"
            }
        }

        var isSelectable: Bool {
            switch self {
            case .command(let c): c.isEnabled
            case .noResults: false
            default: true
            }
        }
    }

    struct Section: Identifiable {
        enum Kind: String, CaseIterable {
            case topHit = "Top Hit"
            case conversations = "Conversations"
            case commands = "Commands"
            case people = "People"
            case messages = "Messages"
        }

        let kind: Kind
        var rows: [Row]
        var isLoading = false
        var id: Kind { kind }
    }

    var query = "" {
        didSet {
            guard oldValue != query else { return }
            highlighted = 0
            recompute()
            scheduleServerSearch()
        }
    }

    private(set) var sections: [Section] = []
    /// A direct conversation is being created for a person that was chosen.
    private(set) var isCreating = false
    private(set) var creationError: String?

    /// Index into `selectableRows`.
    var highlighted = 0

    private var people: [DirectoryEntry] = []
    private var messages: [MessageSearchHit] = []
    private var isSearchingPeople = false
    private var isSearchingMessages = false
    private var serverTask: Task<Void, Never>?
    private var generation = 0

    private let conversations: () -> [Conversation]
    private let commands: () -> AppCommandRegistry
    private let session: Session?

    /// The two lists are read live, so the palette sees a conversation that arrived, or a
    /// command whose title changed, while it was open.
    init(session: Session?, conversations: @escaping () -> [Conversation], commands: @escaping () -> AppCommandRegistry) {
        self.session = session
        self.conversations = conversations
        self.commands = commands
        recompute()
    }

    // MARK: - Rows

    var selectableRows: [Row] {
        sections.flatMap(\.rows).filter(\.isSelectable)
    }

    var highlightedRow: Row? {
        let rows = selectableRows
        return rows.indices.contains(highlighted) ? rows[highlighted] : nil
    }

    func move(_ offset: Int) {
        let count = selectableRows.count
        guard count > 0 else { return }
        highlighted = min(max(highlighted + offset, 0), count - 1)
    }

    /// ⌘↑ / ⌘↓: the first row of the previous or next section.
    func moveSection(_ offset: Int) {
        let rows = selectableRows
        guard let current = highlightedRow, let section = sections.firstIndex(where: { $0.rows.contains { $0.id == current.id } }) else { return }
        var target = section + offset
        while sections.indices.contains(target) {
            if let first = sections[target].rows.first(where: \.isSelectable), let index = rows.firstIndex(where: { $0.id == first.id }) {
                highlighted = index
                return
            }
            target += offset
        }
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recompute() {
        let query = trimmedQuery
        var built: [Section] = []

        if query.isEmpty {
            let recent = Array(conversations().prefix(8)).map(Row.conversation)
            if !recent.isEmpty { built.append(Section(kind: .conversations, rows: recent)) }
            let suggested = commands().suggested.map(Row.command)
            if !suggested.isEmpty { built.append(Section(kind: .commands, rows: suggested)) }
            people = []
            messages = []
            sections = built
            return
        }

        var conversationRows = PaletteRanking.rank(conversations(), query: query, limit: 5) { [$0.displayName] }
        var commandRows = PaletteRanking.rank(commands().paletteCommands, query: query, limit: 5) { [$0.title] + $0.aliases }

        // The top hit: the best of what is local, a conversation over a command when
        // they tie. Lifted out of its section rather than shown twice.
        let conversationGrade = conversationRows.first.map { PaletteRanking.grade(query, against: [$0.displayName]) } ?? .none
        let commandGrade = commandRows.first.map { PaletteRanking.grade(query, against: [$0.title] + $0.aliases) } ?? .none
        if conversationGrade >= commandGrade, !conversationRows.isEmpty {
            built.append(Section(kind: .topHit, rows: [.conversation(conversationRows.removeFirst())]))
        } else if let command = commandRows.first, command.isEnabled {
            built.append(Section(kind: .topHit, rows: [.command(commandRows.removeFirst())]))
        }

        if !conversationRows.isEmpty { built.append(Section(kind: .conversations, rows: conversationRows.map(Row.conversation))) }
        if !commandRows.isEmpty { built.append(Section(kind: .commands, rows: commandRows.map(Row.command))) }

        // People the index already has a direct conversation with are under
        // Conversations; the directory adds everyone else.
        let known = Set(conversations().filter(\.isOneToOne).map(\.name))
        let newPeople = people.filter { $0.source != .users || !known.contains($0.identifier) }
        if !newPeople.isEmpty || isSearchingPeople {
            built.append(Section(kind: .people, rows: newPeople.map(Row.person), isLoading: isSearchingPeople))
        }

        if !messages.isEmpty || isSearchingMessages {
            var rows = messages.map(Row.message)
            if !messages.isEmpty { rows.append(.seeAllMessages) }
            built.append(Section(kind: .messages, rows: rows, isLoading: isSearchingMessages))
        }

        if built.isEmpty {
            built.append(Section(kind: .conversations, rows: [.noResults]))
        }
        sections = built
    }

    // MARK: - The server

    private static let serverMinimumLength = 2
    private static let debounce: Duration = .milliseconds(250)

    private func scheduleServerSearch() {
        serverTask?.cancel()
        generation += 1
        let generation = generation
        let term = trimmedQuery
        guard let session, term.count >= Self.serverMinimumLength else {
            people = []
            messages = []
            isSearchingPeople = false
            isSearchingMessages = false
            recompute()
            return
        }
        isSearchingPeople = true
        isSearchingMessages = true
        recompute()
        serverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            async let peopleResult = session.directory.search(term, limit: 8)
            async let messagesResult = session.messageSearch.searchMessages(term: term, limit: 5)
            // Each lands on its own; a failure leaves its section out, nothing more.
            let foundPeople = (try? await peopleResult) ?? []
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.people = Array(foundPeople.prefix(4))
            self.isSearchingPeople = false
            self.recompute()
            let foundMessages = (try? await messagesResult)?.hits ?? []
            guard self.generation == generation, !Task.isCancelled else { return }
            self.messages = Array(foundMessages.prefix(5))
            self.isSearchingMessages = false
            self.recompute()
        }
    }

    func cancel() {
        serverTask?.cancel()
    }

    // MARK: - People

    /// The direct conversation the index already has with this person, if any.
    func existingConversation(with entry: DirectoryEntry) -> Conversation? {
        guard entry.source == .users else { return nil }
        return conversations().first { $0.isOneToOne && $0.name == entry.identifier }
    }

    /// A conversation with this person, group or team — the existing one, or a new one.
    /// Talk returns the existing direct conversation itself when there is one.
    func conversation(for entry: DirectoryEntry) async -> Conversation? {
        if let existing = existingConversation(with: entry) { return existing }
        guard let session else { return nil }
        isCreating = true
        creationError = nil
        defer { isCreating = false }
        let request: NewConversation = entry.isGroupLike
            ? .group(named: entry.label, inviting: entry)
            : .oneToOne(with: entry.identifier)
        do {
            return try await session.conversations.create(request).conversation
        } catch {
            creationError = "Couldn't start a conversation with \(entry.label)."
            return nil
        }
    }
}
