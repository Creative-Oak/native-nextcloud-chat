import Foundation

/// Sending, editing, deleting and reacting.
///
/// Every one of these is optimistic: the UI changes first, the request follows, and a
/// failure is shown in place rather than as an alert. The reconciliation rules live in
/// ``MessageTimeline`` and are unit-tested there.
extension ChatModel {
    var me: MessageActor {
        MessageActor(kind: .users, id: session.account.userID, displayName: session.account.resolvedDisplayName)
    }

    var canSend: Bool {
        conversation.canPostMessages && !trimmedDraft.isEmpty && trimmedDraft.count <= capabilities.config.effectiveMaxMessageLength
    }

    var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters remaining, shown only when the user gets close to the server's limit.
    var remainingCharacters: Int? {
        let maximum = capabilities.config.effectiveMaxMessageLength
        let remaining = maximum - draftText.count
        return remaining <= 200 ? remaining : nil
    }

    // MARK: - Send

    func send() {
        if editing != nil {
            commitEdit()
            return
        }

        let text = trimmedDraft
        guard !text.isEmpty, conversation.canPostMessages else { return }

        let reference = ReferenceID.generate()
        let replyTo = replyingTo?.messageID
        let optimistic = Message(
            messageID: 0,
            localID: ReferenceID.localID(for: reference),
            token: token,
            actor: me,
            timestamp: Date(),
            text: text,
            parameters: [:],
            isReplyable: true,
            referenceID: reference,
            parent: replyingTo.map { parent in
                ParentMessage(
                    messageID: parent.messageID,
                    actor: parent.actor,
                    text: parent.text,
                    parameters: parent.parameters,
                    isDeleted: parent.isDeleted,
                    timestamp: parent.timestamp
                )
            },
            // Talk only renders Markdown when it says so; assume it for our own message so
            // the bubble matches what everyone else will see.
            isMarkdown: capabilities.supportsMarkdown,
            deliveryState: .sending
        )

        timeline.addPending(optimistic)
        draftText = ""
        replyingTo = nil
        saveDraftNow()
        isScrolledToLatest = true

        transmit(optimistic, replyTo: replyTo)
    }

    /// Retries a send that failed. Same reference id, so a message the server actually did
    /// receive reconciles instead of being duplicated.
    func retry(_ message: Message) {
        guard message.deliveryState.isPending else { return }
        timeline.updateDeliveryState(localID: message.localID, to: .sending)
        transmit(message, replyTo: message.parent?.messageID)
    }

    func discard(_ message: Message) {
        guard message.deliveryState.isPending else { return }
        timeline.remove(localID: message.localID)
        Task { [session, token] in
            await session.store.deleteMessage(localID: message.localID, token: token, accountID: session.account.id)
        }
    }

    private func transmit(_ optimistic: Message, replyTo: Int?) {
        Task { [session, token] in
            do {
                let sent = try await session.chat.send(
                    token: token,
                    message: optimistic.text,
                    replyTo: replyTo,
                    // Only send a reference id the server knows what to do with.
                    referenceID: capabilities.supportsReferenceIDs ? optimistic.referenceID : nil
                )
                // The long poll may have delivered this already; the timeline handles both
                // orders and will not duplicate.
                timeline.apply([sent])
                await session.store.save(messages: [sent], accountID: session.account.id)
                await session.store.deleteMessage(localID: optimistic.localID, token: token, accountID: session.account.id)
            } catch {
                timeline.updateDeliveryState(localID: optimistic.localID, to: .failed(reason: error.userMessage))
                // Keep failed sends across relaunches so nothing the user typed is lost.
                if let failed = timeline.message(localID: optimistic.localID) {
                    await session.store.save(messages: [failed], accountID: session.account.id)
                }
                Log.chat.warning("Send failed: \(error.userMessage)")
            }
        }
    }

    // MARK: - Reply

    func beginReply(to message: Message) {
        guard capabilities.supportsReplies, message.isReplyable, conversation.canPostMessages else { return }
        editing = nil
        replyingTo = message
        saveDraftNow()
    }

    func cancelReply() {
        replyingTo = nil
        saveDraftNow()
    }

    // MARK: - Edit

    func canEdit(_ message: Message) -> Bool {
        guard session.account.isMe(message.actor), message.isEditable else { return false }
        return conversation.isNoteToSelf ? capabilities.canEditNoteToSelfMessages : capabilities.canEditMessages
    }

    /// ⌘↑ — edit the most recent message of mine that can still be edited.
    func beginEditingLatestOwnMessage() {
        guard let message = timeline.messages.last(where: { canEdit($0) && !$0.deliveryState.isPending }) else { return }
        beginEdit(message)
    }

    func beginEdit(_ message: Message) {
        guard canEdit(message) else { return }
        replyingTo = nil
        editing = message
        draftText = message.text
        saveDraftNow()
    }

    func cancelEdit() {
        editing = nil
        draftText = ""
        saveDraftNow()
    }

    private func commitEdit() {
        guard let original = editing else { return }
        let text = trimmedDraft
        guard !text.isEmpty, text != original.text else {
            cancelEdit()
            return
        }

        // Show the edit immediately; the server's version replaces it a moment later.
        var optimistic = original
        optimistic.text = text
        optimistic.lastEdit = Message.EditInfo(actor: me, timestamp: Date())
        timeline.apply([optimistic])

        editing = nil
        draftText = ""
        saveDraftNow()

        Task { [session, token] in
            do {
                let updated = try await session.chat.edit(token: token, messageID: original.messageID, message: text)
                timeline.apply([updated])
                await session.store.save(messages: [updated], accountID: session.account.id)
            } catch {
                timeline.apply([original])   // put the original text back
                lastError = error
                Log.chat.warning("Edit failed: \(error.userMessage)")
            }
        }
    }

    // MARK: - Delete

    func canDelete(_ message: Message) -> Bool {
        guard message.isDeletable else { return false }
        guard session.account.isMe(message.actor) || conversation.isModerator else { return false }
        return capabilities.canDelete(message)
    }

    func delete(_ message: Message) {
        guard canDelete(message) else { return }
        Task { [session, token] in
            do {
                // The response is the replacement tombstone, which is also what every other
                // client will receive — so the row is overwritten, not removed.
                let tombstone = try await session.chat.delete(token: token, messageID: message.messageID)
                timeline.apply([tombstone])
                await session.store.save(messages: [tombstone], accountID: session.account.id)
            } catch {
                lastError = error
                Log.chat.warning("Delete failed: \(error.userMessage)")
            }
        }
    }

    // MARK: - Reactions

    func canReact(_ message: Message) -> Bool {
        capabilities.supportsReactions && conversation.canReact && !message.isSystem && !message.deliveryState.isPending
    }

    /// Adds or removes my reaction. Optimistic, then reconciled with the server's full map.
    func toggleReaction(_ emoji: String, on message: Message) {
        guard canReact(message) else { return }
        let hadReacted = message.myReactions.contains(emoji)

        var optimistic = message
        if hadReacted {
            optimistic.myReactions.remove(emoji)
            let count = (optimistic.reactions[emoji] ?? 1) - 1
            if count > 0 { optimistic.reactions[emoji] = count } else { optimistic.reactions[emoji] = nil }
        } else {
            optimistic.myReactions.insert(emoji)
            optimistic.reactions[emoji] = (optimistic.reactions[emoji] ?? 0) + 1
        }
        timeline.apply([optimistic])

        Task { [session, token] in
            do {
                let summary = hadReacted
                    ? try await session.reactions.remove(emoji, token: token, messageID: message.messageID)
                    : try await session.reactions.add(emoji, token: token, messageID: message.messageID)
                timeline.applyReactions(summary, toMessageID: message.messageID)
                if let updated = timeline.message(id: message.messageID) {
                    await session.store.save(messages: [updated], accountID: session.account.id)
                }
            } catch {
                timeline.apply([message])   // revert
                lastError = error
                Log.chat.warning("Reaction failed: \(error.userMessage)")
            }
        }
    }

    /// The quick strip offered on hover, before the full emoji picker.
    static let quickReactions = ["👍", "❤️", "😂", "🎉", "🙏", "👀"]
}
