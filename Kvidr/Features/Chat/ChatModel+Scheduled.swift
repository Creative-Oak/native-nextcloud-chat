import Foundation

/// Send Later: messages the server holds and sends at their time, whether or not kvidr is
/// running. Only their author sees them, at the foot of the conversation, until they go out.
extension ChatModel {
    var canSchedule: Bool {
        capabilities.supportsScheduledMessages && conversation.canPostMessages
    }

    func loadScheduled() async {
        guard capabilities.supportsScheduledMessages else { return }
        do throws(TalkError) {
            scheduled = try await session.scheduledMessages.scheduled(token: token)
            watchForSending()
        } catch {
            Log.ui.warning("Couldn’t load scheduled messages: \(error.userMessage)")
        }
    }

    /// Sends the composer's words at the Send Later time — or saves the changes to a
    /// scheduled message taken back into the composer.
    func sendScheduled() {
        guard canSend else { return }
        let text = trimmedDraft
        let editing = editingScheduled
        guard let sendAt = sendLater ?? editing?.sendAt else { return }
        let replyTo = replyingTo.flatMap { $0.token == token ? $0.messageID : nil }

        draftText = ""
        replyingTo = nil
        sendLater = nil
        editingScheduled = nil
        saveDraftNow()

        let service = session.scheduledMessages
        let token = self.token
        let threadID = openThread?.id
        Task { [weak self] in
            do throws(TalkError) {
                if let editing {
                    try await service.update(token: token, id: editing.id, text: text, sendAt: sendAt, silent: editing.isSilent)
                } else {
                    try await service.schedule(token: token, text: text, sendAt: sendAt, replyTo: replyTo, threadID: threadID)
                }
                await self?.loadScheduled()
            } catch {
                // Put the words back rather than lose them.
                guard let self else { return }
                if self.draftText.isEmpty { self.draftText = text }
                self.sendLater = sendAt
                self.editingScheduled = editing
                self.lastError = error
            }
        }
    }

    func reschedule(_ message: ScheduledMessage, to date: Date) {
        let previous = scheduled
        if let index = scheduled.firstIndex(where: { $0.id == message.id }) {
            scheduled[index].sendAt = date
            scheduled[index].failedSendAt = nil
            scheduled.sort { $0.sendAt < $1.sendAt }
        }
        let service = session.scheduledMessages
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                try await service.update(token: token, id: message.id, text: message.text, sendAt: date, silent: message.isSilent)
                await self?.loadScheduled()
            } catch {
                self?.scheduled = previous
                self?.lastError = error
            }
        }
    }

    /// Sends it straight away: the scheduled copy is taken off the server and the words go
    /// out as an ordinary message, as a reply if they were one.
    func sendNow(_ message: ScheduledMessage) {
        deleteScheduled(message)
        let previousDraft = draftText
        let previousReply = replyingTo
        draftText = message.text
        replyingTo = message.parent.flatMap { parent in timeline.message(id: parent.messageID) }
        sendLater = nil
        editingScheduled = nil
        send()
        draftText = previousDraft
        replyingTo = previousReply
    }

    func deleteScheduled(_ message: ScheduledMessage) {
        let previous = scheduled
        scheduled.removeAll { $0.id == message.id }
        let service = session.scheduledMessages
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                try await service.delete(token: token, id: message.id)
            } catch .notFound {
                // Already sent, or deleted elsewhere.
            } catch {
                self?.scheduled = previous
                self?.lastError = error
            }
        }
    }

    /// Takes a scheduled message back into the composer to change its words.
    func editScheduled(_ message: ScheduledMessage) {
        editing = nil
        replyingTo = nil
        editingScheduled = message
        sendLater = message.sendAt
        draftText = message.text
    }

    /// + ▸ Send Later: an hour from now, on the next five minutes, to be adjusted in place.
    func beginSendLater(at date: Date? = nil) {
        guard canSchedule else { return }
        if let date {
            sendLater = date
            return
        }
        let inAnHour = Date().addingTimeInterval(60 * 60)
        let fiveMinutes: TimeInterval = 5 * 60
        sendLater = Date(timeIntervalSince1970: (inAnHour.timeIntervalSince1970 / fiveMinutes).rounded(.up) * fiveMinutes)
    }

    func cancelSendLater() {
        if editingScheduled != nil { draftText = "" }
        sendLater = nil
        editingScheduled = nil
    }

    /// Reads the list again shortly after the next one is due, so a sent message leaves the
    /// foot of the conversation without waiting for anything else to happen.
    func watchForSending() {
        scheduledRefresh?.cancel()
        guard let next = scheduled.filter({ !$0.hasFailed }).map(\.sendAt).min() else { return }
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(next.timeIntervalSinceNow, 0) + 20))
            guard !Task.isCancelled else { return }
            await self?.loadScheduled()
        }
    }
}
