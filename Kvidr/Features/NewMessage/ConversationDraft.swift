import Foundation
import Observation

/// A conversation you are addressing but have not sent yet.
///
/// It exists only here: nothing reaches the server until the first message goes, so the ×
/// on its sidebar row throws away a local object rather than deleting anything. See
/// `docs/plans/2026-09-15-new-message-draft-design.md`.
///
/// Most of this is the old New Conversation sheet's people search, re-homed. What it loses
/// is the type picker and the name field: the recipients decide the type, and the name is
/// derived from them.
@MainActor
@Observable
final class ConversationDraft {
    /// Who it is addressed to, in the order they were added.
    private(set) var recipients: [DirectoryEntry] = []
    /// Anyone on the server may join, whatever the recipient count.
    var isOpen = false
    /// The first message. Kept here so clicking away to another conversation and back does
    /// not lose what you had typed.
    var text = ""
    /// Bumped every time ⌘N is pressed, the second one included. The view watches it rather
    /// than only its own appearance, or asking for a new message while a draft is already
    /// open would select the row and leave the cursor wherever it was.
    private(set) var focusRequest = 0

    var search = "" {
        didSet {
            guard oldValue != search else { return }
            scheduleSearch()
        }
    }

    private(set) var results: [DirectoryEntry] = []
    /// Which match the arrow keys are on. Reset whenever the matches change, since the row
    /// that was highlighted is rarely the same row afterwards.
    private(set) var highlighted = 0
    private(set) var isSearching = false
    private(set) var isSending = false
    private(set) var error: String?

    /// Files staged before there is anywhere to put them. Uploading needs no conversation —
    /// only sharing does — so they go up while you are still deciding who to send them to.
    let attachments: AttachmentQueue

    private let session: Session
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(session: Session) {
        self.session = session
        self.attachments = AttachmentQueue(session: session)
    }

    func requestRecipientFocus() {
        focusRequest += 1
    }

    /// The match Return would take.
    var highlightedResult: DirectoryEntry? {
        results.indices.contains(highlighted) ? results[highlighted] : nil
    }

    func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }

    func highlight(_ index: Int) {
        guard results.indices.contains(index) else { return }
        highlighted = index
    }

    /// Takes the highlighted match, if there is one. Return in the To: field.
    @discardableResult
    func acceptHighlighted() -> Bool {
        guard let entry = highlightedResult else { return false }
        toggle(entry)
        return true
    }

    // MARK: - Recipients

    /// What the sidebar row and the window title call it.
    var title: String {
        recipients.isEmpty ? "New Message" : NewConversation.name(for: recipients)
    }

    var canSend: Bool {
        guard !recipients.isEmpty, !isSending else { return false }
        // A picture with nothing typed is a message, the same as it is in a conversation.
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments.hasStaged
    }

    /// What this will become — `nil` until somebody is in it.
    var plan: NewConversation? {
        NewConversation.draft(recipients: recipients, isOpen: isOpen)
    }

    func isRecipient(_ entry: DirectoryEntry) -> Bool {
        recipients.contains(entry)
    }

    func toggle(_ entry: DirectoryEntry) {
        if let index = recipients.firstIndex(of: entry) {
            recipients.remove(at: index)
        } else {
            recipients.append(entry)
            // The search has served its purpose; leaving the term behind leaves the results
            // list open over a field you are done with.
            search = ""
            results = []
            highlighted = 0
        }
        error = nil
    }

    /// Escape: drop the matches without dropping what was typed.
    func clearSearch() {
        results = []
        highlighted = 0
    }

    func remove(_ entry: DirectoryEntry) {
        recipients.removeAll { $0 == entry }
    }

    /// Backspace at the start of an empty field, as in Messages.
    func removeLastRecipient() {
        guard search.isEmpty, !recipients.isEmpty else { return }
        recipients.removeLast()
    }

    // MARK: - Searching

    private func scheduleSearch() {
        searchTask?.cancel()
        let term = search
        guard term.count >= 2 else {
            results = []
            isSearching = false
            return
        }

        // Local matches, straight away and without waiting for the network: the corpus is
        // already here once the contact browser has filled it.
        results = DirectoryEntry.matches(for: term, server: [], known: contacts, excluding: recipients)
        highlighted = 0

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            defer { self.isSearching = false }
            do throws(TalkError) {
                // People, groups and teams all: unlike the old sheet, the kind is not chosen
                // in advance, so nothing can be ruled out of the results.
                let found = try await self.session.directory.search(term, shareTypes: [0, 1, 7])
                guard !Task.isCancelled, self.search == term else { return }
                // The server's matches, plus anyone already listed whose letters are merely
                // in order — which the server's own matching will not find.
                self.results = DirectoryEntry.matches(
                    for: term,
                    server: found,
                    known: self.contacts,
                    excluding: self.recipients
                )
                self.highlighted = 0
            } catch {
                self.results = []
                self.error = error.userMessage
            }
        }
    }

    // MARK: - Browsing

    /// Everyone the server is willing to list, for the + button's contact browser.
    private(set) var contacts: [DirectoryEntry] = []
    private(set) var isBrowsingContacts = false
    private(set) var didBrowse = false

    /// Asks for a page of contacts with no search term at all.
    ///
    /// An empty answer is ambiguous and the endpoint cannot disambiguate it: a server with
    /// user enumeration turned off returns nothing here and looks exactly like a server with
    /// nobody on it. The browser says as much rather than showing an empty list.
    func browseContacts() async {
        guard !isBrowsingContacts, !didBrowse else { return }
        isBrowsingContacts = true
        defer {
            isBrowsingContacts = false
            didBrowse = true
        }
        do throws(TalkError) {
            contacts = try await session.directory.search("", limit: 100, allowingEmptyTerm: true)
        } catch {
            contacts = []
            self.error = error.userMessage
        }
    }

    // MARK: - Sending

    /// Creates the conversation and sends the first message into it.
    ///
    /// - Returns: the conversation, once it exists. `nil` means nothing was created and the
    ///   draft should stay exactly as it is.
    func send() async -> Conversation? {
        guard let plan, canSend else { return nil }
        isSending = true
        error = nil
        defer { isSending = false }

        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let created: CreatedConversation
        do throws(TalkError) {
            created = try await session.conversations.create(plan)
        } catch {
            // Nothing was made, so nothing is lost: the recipients and the typed message are
            // still here for another go.
            self.error = error.userMessage
            return nil
        }

        // Anything staged goes into the conversation that now exists, with the typed words
        // as the first one's caption — the same rule as sending into a conversation. The
        // queue itself is handed on to the new `ChatModel`, since its uploads may still be
        // running and the draft is about to be thrown away.
        if attachments.hasStaged {
            attachments.adopt(token: created.conversation.token)
            attachments.send(caption: message, replyTo: nil)
            return created.conversation
        }

        do throws(TalkError) {
            _ = try await session.chat.send(token: created.conversation.token, message: message)
        } catch {
            // The conversation is real even though its first message is not. Discarding the
            // draft now would orphan it, so the caller opens it anyway and the message is
            // retried there like any other that failed to send.
            Log.chat.warning("Made \(created.conversation.token) but its first message failed: \(error.userMessage)")
        }

        return created.conversation
    }
}
