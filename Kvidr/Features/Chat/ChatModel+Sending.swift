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

    /// Whether the send button should light up.
    ///
    /// Kept in step with `send()` below, deliberately: a picture with nothing typed is a
    /// message, and when only `send()` knew that, Return worked while the button beside it
    /// stayed grey.
    var canSend: Bool {
        guard conversation.canPostMessages else { return false }
        // Only words can be scheduled.
        if sendLater != nil || editingScheduled != nil {
            return !trimmedDraft.isEmpty && !attachments.hasStaged
                && trimmedDraft.count <= capabilities.config.effectiveMaxMessageLength
        }
        guard !trimmedDraft.isEmpty || attachments.hasStaged else { return false }
        // The words become the attachment's caption, and a caption is a message as far as
        // the length limit is concerned.
        return trimmedDraft.count <= capabilities.config.effectiveMaxMessageLength
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
        if sendLater != nil || editingScheduled != nil {
            // A scheduled message has no id for days; a reminder can't wait that long for
            // one, and quietly keeping it armed until then would be a promise we'd break.
            armedReminder = nil
            sendScheduled()
            return
        }

        // The same question the button asks, rather than a second version of it. Stating the
        // rule twice is what let Return and the button disagree: Return would send a message
        // too long for the server, and the button would not send a picture with no words.
        guard canSend else { return }
        let text = trimmedDraft

        // With something staged, the words ride along as its caption rather than arriving as
        // a message of their own.
        // See docs/plans/2026-09-15-attachments-photos-polls-design.md § 1.
        if attachments.hasStaged {
            // A file's share can't quote a message from another conversation, so a private
            // reply with a file goes without the quote.
            attachments.send(caption: text, replyTo: replyingTo.flatMap { $0.token == token ? $0.messageID : nil })
            draftText = ""
            replyingTo = nil
            // The upload's own message is the one that would carry it, and this isn't it.
            armedReminder = nil
            return
        }

        let reference = ReferenceID.generate()
        let replyTo = replyingTo?.messageID
        let replyToToken = replyingTo.flatMap { $0.token != token ? $0.token : nil }
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
                    timestamp: parent.timestamp,
                    token: replyToToken
                )
            },
            // Talk only renders Markdown when it says so; assume it for our own message so
            // the bubble matches what everyone else will see.
            isMarkdown: capabilities.supportsMarkdown,
            deliveryState: .sending
        )

        mutateTimeline { $0.addPending(optimistic) }
        draftText = ""
        replyingTo = nil
        // Taken off the composer now, and set only if the send actually lands.
        let reminder = armedReminder
        armedReminder = nil
        saveDraftNow()
        isScrolledToLatest = true

        transmit(optimistic, replyTo: replyTo, replyToToken: replyToToken, reminder: reminder)
    }

    /// Retries a send that failed. Same reference id, so a message the server actually did
    /// receive reconciles instead of being duplicated.
    func retry(_ message: Message) {
        guard message.deliveryState.isPending else { return }
        mutateTimeline { $0.updateDeliveryState(localID: message.localID, to: .sending) }
        transmit(message, replyTo: message.parent?.messageID, replyToToken: message.parent?.token)
    }

    func discard(_ message: Message) {
        guard message.deliveryState.isPending else { return }
        mutateTimeline { $0.remove(localID: message.localID) }
        let store = session.store
        let accountID = session.account.id
        let token = self.token
        Task { await store.deleteMessage(localID: message.localID, token: token, accountID: accountID) }
    }

    private func transmit(_ optimistic: Message, replyTo: Int?, replyToToken: String?, reminder: ArmedReminder? = nil) {
        // Only send a reference id the server knows what to do with.
        let referenceID = capabilities.supportsReferenceIDs ? optimistic.referenceID : nil

        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            let token = self.token
            do throws(TalkError) {
                let sent = try await session.chat.send(
                    token: token,
                    message: optimistic.text,
                    replyTo: replyTo,
                    replyToToken: replyToToken,
                    referenceID: referenceID
                )
                // The long poll may have delivered this already; the timeline handles both
                // orders and will not duplicate.
                self.mutateTimeline { $0.apply([sent]) }
                // The message exists now, so the time clicked in the draft has something to
                // hang on. A send that failed sets nothing, which is the right answer.
                if let reminder { self.onArmedReminder(sent, reminder.date) }
                await session.store.save(messages: [sent], accountID: session.account.id)
                await session.store.deleteMessage(localID: optimistic.localID, token: token, accountID: session.account.id)
            } catch {
                self.mutateTimeline {
                    $0.updateDeliveryState(localID: optimistic.localID, to: .failed(reason: error.userMessage))
                }
                // Keep failed sends across relaunches so nothing the user typed is lost.
                if let failed = self.timeline.message(localID: optimistic.localID) {
                    await session.store.save(messages: [failed], accountID: session.account.id)
                }
                Log.chat.warning("Send failed: \(error.userMessage)")
            }
        }
    }

    // MARK: - Reply

    func beginReply(to message: Message) {
        guard capabilities.supportsReplies, message.isReplyable, conversation.canPostMessages else { return }
        // A message from elsewhere is a private reply, which this conversation has to be the
        // one-to-one with its author for.
        if message.token != token {
            guard capabilities.supportsPrivateReply, conversation.isOneToOne, conversation.name == message.actor.id else { return }
        }
        editing = nil
        replyingTo = message
        saveDraftNow()
    }

    /// Whether the message's menu offers Reply Privately.
    func canReplyPrivately(to message: Message) -> Bool {
        capabilities.supportsPrivateReply
            && message.canBeRepliedToPrivately(in: conversation, myUserID: session.account.userID)
    }

    /// Whether the reply being written quotes a message from another conversation.
    var isReplyingPrivately: Bool {
        replyingTo.map { $0.token != token } ?? false
    }

    func cancelReply() {
        replyingTo = nil
        saveDraftNow()
    }

    /// ⇧⌘R — reply to the newest message that can be replied to.
    func replyToLatest() {
        guard let message = timeline.messages.last(where: { $0.isReplyable && !$0.deliveryState.isPending && !$0.isSystem })
        else { return }
        beginReply(to: message)
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
        mutateTimeline { $0.apply([optimistic]) }

        editing = nil
        draftText = ""
        saveDraftNow()

        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            do throws(TalkError) {
                let updated = try await session.chat.edit(token: self.token, messageID: original.messageID, message: text)
                self.mutateTimeline { $0.apply([updated]) }
                await session.store.save(messages: [updated], accountID: session.account.id)
            } catch {
                self.mutateTimeline { $0.apply([original]) }   // put the original text back
                self.lastError = error
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
        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            do throws(TalkError) {
                // The response is the replacement tombstone, which is also what every other
                // client will receive — so the row is overwritten, not removed.
                let tombstone = try await session.chat.delete(token: self.token, messageID: message.messageID)
                self.mutateTimeline { $0.apply([tombstone]) }
                await session.store.save(messages: [tombstone], accountID: session.account.id)
            } catch {
                self.lastError = error
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
        mutateTimeline { $0.apply([optimistic]) }

        Task { [weak self] in
            guard let self else { return }
            let session = self.session
            let token = self.token
            do throws(TalkError) {
                let summary = hadReacted
                    ? try await session.reactions.remove(emoji, token: token, messageID: message.messageID)
                    : try await session.reactions.add(emoji, token: token, messageID: message.messageID)
                self.mutateTimeline { $0.applyReactions(summary, toMessageID: message.messageID) }
                if let updated = self.timeline.message(id: message.messageID) {
                    await session.store.save(messages: [updated], accountID: session.account.id)
                }
            } catch {
                self.mutateTimeline { $0.apply([message]) }   // revert
                self.lastError = error
                Log.chat.warning("Reaction failed: \(error.userMessage)")
            }
        }
    }

    /// The quick strip offered on hover, before the full emoji picker.
    static let quickReactions = ["👍", "❤️", "😂", "🎉", "🙏", "👀"]
}
