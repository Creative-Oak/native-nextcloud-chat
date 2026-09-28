import Foundation
import Observation

/// State for the third column.
///
/// Loads lazily and per tab: opening the inspector on Info costs nothing, and the
/// participant list is only fetched when someone actually looks at People.
@MainActor
@Observable
final class InspectorModel {
    enum Tab: String, CaseIterable, Identifiable {
        case details, people, files
        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: String(localized: "Info", comment: "Inspector tab: about the conversation")
            case .people: String(localized: "People", comment: "Inspector tab: the participants")
            case .files: String(localized: "Files", comment: "Inspector tab: what has been shared")
            }
        }

        var symbolName: String {
            switch self {
            case .details: "info.circle"
            case .people: "person.2"
            case .files: "paperclip"
            }
        }
    }

    var tab: Tab = .details {
        didSet { Task { await loadIfNeeded() } }
    }

    private(set) var conversation: Conversation
    private(set) var participants: [Participant] = []
    private(set) var sharedItems: [SharedItemType: [Message]] = [:]
    private(set) var isLoading = false
    private(set) var error: TalkError?

    /// People search for the "Add someone" field.
    var inviteSearch = "" {
        didSet { scheduleInviteSearch() }
    }
    private(set) var inviteResults: [DirectoryEntry] = []
    private(set) var isInviting = false

    private let session: Session
    private var loadedTabs: Set<Tab> = []
    @ObservationIgnored private var inviteTask: Task<Void, Never>?

    init(session: Session, conversation: Conversation) {
        self.session = session
        self.conversation = conversation
    }

    var capabilities: TalkCapabilities { session.capabilitySnapshot }
    var canManageParticipants: Bool { conversation.isModerator && !conversation.isOneToOne }
    var showsFilesTab: Bool { capabilities.supportsSharedItems }

    var availableTabs: [Tab] {
        Tab.allCases.filter { $0 != .files || showsFilesTab }
    }

    func update(conversation: Conversation) {
        self.conversation = conversation
    }

    func loadIfNeeded(force: Bool = false) async {
        if force { loadedTabs.remove(tab) }
        guard !loadedTabs.contains(tab) else { return }
        loadedTabs.insert(tab)

        isLoading = true
        defer { isLoading = false }

        do throws(TalkError) {
            switch tab {
            case .details:
                break   // already have everything
            case .people:
                participants = try await session.participants.participants(token: conversation.token)
            case .files:
                sharedItems = try await session.sharedItems.overview(token: conversation.token)
            }
            error = nil
        } catch {
            self.error = error
            loadedTabs.remove(tab)
            Log.ui.warning("Inspector load failed: \(error.userMessage)")
        }
    }

    // MARK: - Participants

    func remove(_ participant: Participant) async {
        guard canManageParticipants else { return }
        let previous = participants
        participants.removeAll { $0.attendeeID == participant.attendeeID }
        do throws(TalkError) {
            try await session.participants.remove(attendeeID: participant.attendeeID, from: conversation.token)
        } catch {
            participants = previous
            self.error = error
        }
    }

    func invite(_ entry: DirectoryEntry) async {
        guard canManageParticipants else { return }
        isInviting = true
        defer { isInviting = false }
        do throws(TalkError) {
            try await session.participants.add(entry, to: conversation.token)
            inviteSearch = ""
            inviteResults = []
            await loadIfNeeded(force: true)
        } catch {
            self.error = error
        }
    }

    private func scheduleInviteSearch() {
        inviteTask?.cancel()
        let term = inviteSearch
        guard term.count >= 2 else {
            inviteResults = []
            return
        }

        inviteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.session.directory.search(term, inConversation: self.conversation.token)
                guard !Task.isCancelled, self.inviteSearch == term else { return }
                // Don't offer people who are already here.
                let existing = Set(self.participants.map(\.actor.id))
                self.inviteResults = results.filter { !($0.source == .users && existing.contains($0.identifier)) }
            } catch {
                self.inviteResults = []
            }
        }
    }

    // MARK: - Files

    func items(for type: SharedItemType) -> [Message] {
        sharedItems[type] ?? []
    }

    var populatedItemTypes: [SharedItemType] {
        SharedItemType.displayOrder.filter { !(sharedItems[$0]?.isEmpty ?? true) }
    }
}
