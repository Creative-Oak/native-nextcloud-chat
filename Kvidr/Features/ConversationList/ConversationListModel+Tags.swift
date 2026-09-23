import Foundation

/// Asking for a tag's name.
struct TagNaming: Identifiable {
    enum Purpose {
        /// A new tag — for this conversation, if one was right-clicked.
        case new(forToken: String?)
        case rename(ConversationTag)
    }

    let id = UUID()
    let purpose: Purpose
    var name: String

    var title: String {
        if case .rename = purpose { return "Rename Tag" }
        return "New Tag"
    }
}

/// The user's own groups in the sidebar — Talk's conversation tags: sections of their own,
/// between the favourites and the rest, in an order the user sets, folded or not. Changes show
/// at once and are undone if the server refuses them. Cap `conversation-tags`.
extension ConversationListModel {
    var hasTags: Bool { session.capabilitySnapshot.has("conversation-tags") }

    /// The user's own, without Talk's built-in two.
    var customTags: [ConversationTag] { tags.filter { $0.kind == .custom } }

    func loadTags() async {
        guard hasTags else { return }
        do throws(TalkError) {
            let fresh = try await session.tags.tags()
            // One still being made is kept: the server doesn't know it yet.
            tags = Self.placing(tags.filter(\.isPending), in: fresh)
            let known = Set(tags.map(\.id))
            let conversations = index.allConversations
            let tagged = conversations.count { $0.tagIDs.contains(where: known.contains) }
            let strays = Set(conversations.flatMap(\.tagIDs)).subtracting(known)
            Log.ui.notice("Conversation tags: \(self.customTags.count) of your own, \(tagged) conversations in them\(strays.isEmpty ? "" : ", unknown tag ids \(strays.sorted())")")
        } catch {
            Log.ui.warning("Couldn’t load conversation tags: \(error.userMessage)")
        }
    }

    // MARK: - A conversation's tags

    /// In `tag`, or out of it.
    func setTag(_ tag: ConversationTag, _ isOn: Bool, for conversation: Conversation) {
        guard let current = index[conversation.token] else { return }
        var ids = current.tagIDs.filter { id in tags.contains { $0.id == id } }
        ids.removeAll { $0 == tag.id }
        if isOn { ids.append(tag.id) }
        assign(ids, to: current)
    }

    private func assign(_ ids: [String], to conversation: Conversation) {
        let token = conversation.token
        let before = conversation.tagIDs
        pendingTagIDs[token] = PendingTags(ids: ids)
        updateLocally(token) { $0.tagIDs = ids }
        // A tag still being made goes to the server once it has its real id.
        let known = ids.filter { !ConversationTag.isPending($0) }
        let service = session.tags
        Task { [weak self] in
            do throws(TalkError) {
                _ = try await service.assign(known, to: token)
                // Confirmed — unless another change has come since, which is still on its way.
                if self?.pendingTagIDs[token]?.ids == ids, !ids.contains(where: ConversationTag.isPending) {
                    self?.pendingTagIDs[token]?.confirmedAt = .now
                }
            } catch {
                guard let self else { return }
                if self.pendingTagIDs[token]?.ids == ids {
                    self.pendingTagIDs[token] = nil
                    self.updateLocally(token) { $0.tagIDs = before }
                }
                Log.ui.warning("Couldn’t change the conversation’s tags: \(error.userMessage)")
            }
        }
    }

    /// After a refresh: a conversation's tags as they were just set here, not as a refresh that
    /// left before the change reached the server says. Held a little past the server's
    /// confirmation too, for a refresh that was already on its way back.
    func keepPendingTags() {
        for (token, pending) in pendingTagIDs {
            if let confirmed = pending.confirmedAt, Date.now.timeIntervalSince(confirmed) > PendingTags.grace {
                pendingTagIDs[token] = nil
                continue
            }
            guard let current = index[token], current.tagIDs != pending.ids else { continue }
            updateLocally(token) { $0.tagIDs = pending.ids }
        }
    }

    // MARK: - The tags themselves

    func beginNewTag(for conversation: Conversation?) {
        namingTag = TagNaming(purpose: .new(forToken: conversation?.token), name: "")
    }

    func beginRenaming(_ tag: ConversationTag) {
        namingTag = TagNaming(purpose: .rename(tag), name: tag.name)
    }

    /// The name was given.
    func finishNaming() {
        guard let naming = namingTag else { return }
        namingTag = nil
        let name = naming.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let service = session.tags
        switch naming.purpose {
        case .new(let token):
            // Shown at once, with a stand-in id, and the conversation in it; swapped for the
            // server's once it answers, or taken away again if it refuses.
            let pending = ConversationTag(id: ConversationTag.pendingID(), name: name, sortOrder: 0, isCollapsed: false, kind: .custom)
            tags = Self.placing([pending], in: tags)
            if let token, let conversation = index[token] { setTag(pending, true, for: conversation) }
            Task { [weak self] in
                do throws(TalkError) {
                    let made = try await service.create(named: name)
                    Log.ui.notice("Made the tag \(made.id)")
                    self?.resolve(pending.id, as: made)
                } catch {
                    self?.abandon(pending.id)
                    Log.ui.warning("Couldn’t make the tag: \(error.userMessage)")
                }
            }
        case .rename(let tag):
            rename(tag, to: name)
        }
    }

    private func rename(_ tag: ConversationTag, to name: String) {
        update(tag.id) { $0.name = name }
        guard !tag.isPending else { return }
        let service = session.tags
        Task { [weak self] in
            do throws(TalkError) {
                _ = try await service.rename(tag.id, to: name)
            } catch {
                self?.update(tag.id) { $0.name = tag.name }
                Log.ui.warning("Couldn’t rename the tag: \(error.userMessage)")
            }
        }
    }

    /// The tag goes; its conversations go back among the rest.
    func deleteTag(_ tag: ConversationTag) {
        let before = tags
        tags.removeAll { $0.id == tag.id }
        // Still being made: it's deleted on the server when that answers.
        guard !tag.isPending else { return }
        let service = session.tags
        Task { [weak self] in
            do throws(TalkError) {
                try await service.delete(tag.id)
            } catch {
                self?.tags = before
                Log.ui.warning("Couldn’t delete the tag: \(error.userMessage)")
            }
        }
    }

    /// Up (-1) or down (1) among the user's own; Talk's two keep their places.
    func moveTag(_ tag: ConversationTag, by offset: Int) {
        var custom = customTags
        guard let from = custom.firstIndex(of: tag) else { return }
        let to = from + offset
        guard custom.indices.contains(to) else { return }
        custom.swapAt(from, to)
        // The full order, the built-in ones where they were.
        var order = tags
        var next = custom.makeIterator()
        for index in order.indices where order[index].kind == .custom {
            if let tag = next.next() { order[index] = tag }
        }
        for index in order.indices { order[index].sortOrder = index }
        let before = tags
        tags = order
        guard !order.contains(where: \.isPending) else { return }
        let service = session.tags
        let ids = order.map(\.id)
        Task { [weak self] in
            do throws(TalkError) {
                self?.tags = try await service.reorder(ids)
            } catch {
                self?.tags = before
                Log.ui.warning("Couldn’t reorder the tags: \(error.userMessage)")
            }
        }
    }

    /// Folded, a tag still shows what's unread in it, and the conversation that's open.
    func setCollapsed(_ tag: ConversationTag, _ collapsed: Bool) {
        update(tag.id) { $0.isCollapsed = collapsed }
        guard !tag.isPending else { return }
        let service = session.tags
        Task { [weak self] in
            do throws(TalkError) {
                _ = try await service.setCollapsed(collapsed, id: tag.id)
            } catch {
                self?.update(tag.id) { $0.isCollapsed = !collapsed }
                Log.ui.warning("Couldn’t fold the tag: \(error.userMessage)")
            }
        }
    }

    /// The server made the tag: its id replaces the stand-in everywhere, and the
    /// conversations put in it meanwhile are told to the server.
    private func resolve(_ pendingID: String, as made: ConversationTag) {
        if let index = tags.firstIndex(where: { $0.id == pendingID }) {
            var tag = made
            // Renamed or folded while it was being made: that stands.
            tag.name = tags[index].name
            tag.isCollapsed = tags[index].isCollapsed
            tags[index] = tag
            if tag.name != made.name { rename(made, to: tag.name) }
            if tag.isCollapsed { setCollapsed(tag, true) }
        } else {
            // Deleted before the server answered.
            deleteTag(made)
            return
        }
        for conversation in index.allConversations where conversation.tagIDs.contains(pendingID) {
            let ids = conversation.tagIDs.map { $0 == pendingID ? made.id : $0 }
            assign(ids, to: conversation)
        }
        // The server's order, now that it knows the tag.
        Task { await loadTags() }
    }

    /// The server wouldn't make the tag: it goes, from the sidebar and from its conversations.
    private func abandon(_ pendingID: String) {
        tags.removeAll { $0.id == pendingID }
        for conversation in index.allConversations where conversation.tagIDs.contains(pendingID) {
            pendingTagIDs[conversation.token] = nil
            updateLocally(conversation.token) { $0.tagIDs.removeAll { $0 == pendingID } }
        }
    }

    /// New tags go after the user's own and before Talk's "other", as the server puts them.
    static func placing(_ new: [ConversationTag], in existing: [ConversationTag]) -> [ConversationTag] {
        var result = existing
        let at = result.firstIndex { $0.kind == .other } ?? result.endIndex
        result.insert(contentsOf: new, at: at)
        for index in result.indices { result[index].sortOrder = index }
        return result
    }

    private func update(_ id: String, _ change: (inout ConversationTag) -> Void) {
        guard let index = tags.firstIndex(where: { $0.id == id }) else { return }
        change(&tags[index])
    }
}

/// Tags given to a conversation here that a refresh mustn't undo yet.
struct PendingTags {
    /// How long a confirmed change is still held: longer than a list refresh takes.
    static let grace: TimeInterval = 30

    let ids: [String]
    var confirmedAt: Date?
}

extension ConversationTag {
    private static let pendingPrefix = "pending-"

    /// A stand-in id for a tag the server hasn't made yet.
    static func pendingID() -> String { pendingPrefix + UUID().uuidString }

    static func isPending(_ id: String) -> Bool { id.hasPrefix(pendingPrefix) }

    /// Shown already, but not on the server yet.
    var isPending: Bool { Self.isPending(id) }
}
