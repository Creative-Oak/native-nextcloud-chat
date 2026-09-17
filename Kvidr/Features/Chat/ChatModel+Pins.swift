import Foundation

extension PinnedMessage {
    /// The system messages that mean the conversation's pins changed.
    static let changeSystemMessages: Set<String> = ["message_pinned", "message_unpinned"]
}

/// Pinned messages: the bar over the transcript, and pinning from a message's menu.
///
/// Optimistic like everything else here, and then read back from the server, which is the
/// only place that knows when a timed pin has lifted.
extension ChatModel {
    /// Pinning and unpinning are for moderators.
    var canPin: Bool {
        capabilities.supportsPinnedMessages && conversation.isModerator
    }

    /// What the pinned bar shows: the most recent pin still in force, unless this user
    /// dismissed the bar for it.
    var visiblePin: PinnedMessage? {
        guard let latest = pins.first(where: { $0.isActive() }), latest.id != hiddenPinnedID else { return nil }
        return latest
    }

    var activePinCount: Int { pins.count { $0.isActive() } }

    var activePins: [PinnedMessage] { pins.filter { $0.isActive() } }

    /// The bar was hidden, but there are pins: the chip that stands in for it.
    var hasHiddenPins: Bool { visiblePin == nil && activePinCount > 0 }

    func pin(for messageID: Int) -> PinnedMessage? {
        pins.first { $0.id == messageID && $0.isActive() }
    }

    /// Follows the server's rule for a hidden bar: whenever a message becomes the latest pin —
    /// pinned, pinned again after an unpin, or back on top because a newer one was unpinned —
    /// anyone who had hidden the bar for that message sees it again
    /// (`RoomService::setLastPinnedId`). Without this a hide lasted as long as the
    /// conversation stayed open, whatever happened to the pin.
    func pinsChanged() {
        let latest = pins.first { $0.isActive() }?.id ?? 0
        guard latest != latestPinID else { return }
        latestPinID = latest
        if latest != 0, hiddenPinnedID == latest {
            hiddenPinnedID = 0
            onHiddenPinChanged(0)
        }
    }

    /// The sidebar's copy of the conversation changed its hidden pin — hidden or shown on
    /// another device.
    func hiddenPinChangedElsewhere(_ id: Int) {
        guard id != hiddenPinnedID else { return }
        hiddenPinnedID = id
    }

    func loadPins() async {
        guard capabilities.supportsPinnedMessages else { return }
        do throws(TalkError) {
            pins = try await session.pins.pinnedMessages(token: token)
            pinsChanged()
        } catch {
            Log.ui.warning("Couldn’t load pinned messages: \(error.userMessage)")
        }
    }

    func pin(_ message: Message, for duration: PinDuration) {
        guard canPin, message.messageID > 0 else { return }
        let previous = pins
        let until = duration.until()
        pins.removeAll { $0.id == message.messageID }
        pins.insert(PinnedMessage(message: message, pinnedAt: Date(), pinnedUntil: until, pinnedBy: me), at: 0)
        pinsChanged()

        let service = session.pins
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                try await service.pin(token: token, messageID: message.messageID, until: until)
                await self?.loadPins()
            } catch {
                self?.pins = previous
                self?.pinsChanged()
                Log.ui.warning("Couldn’t pin message: \(error.userMessage)")
            }
        }
    }

    func unpin(messageID: Int) {
        guard canPin else { return }
        let previous = pins
        pins.removeAll { $0.id == messageID }
        pinsChanged()

        let service = session.pins
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                try await service.unpin(token: token, messageID: messageID)
                await self?.loadPins()
            } catch {
                self?.pins = previous
                self?.pinsChanged()
                Log.ui.warning("Couldn’t unpin message: \(error.userMessage)")
            }
        }
    }

    /// Dismisses the pinned bar for this user. It comes back when something newer is pinned.
    func hidePinnedBar() {
        guard let pin = visiblePin else { return }
        let previous = hiddenPinnedID
        hiddenPinnedID = pin.id
        onHiddenPinChanged(pin.id)

        let service = session.pins
        let token = self.token
        Task { [weak self] in
            do throws(TalkError) {
                try await service.hideForMe(token: token, messageID: pin.id)
            } catch {
                self?.hiddenPinnedID = previous
                self?.onHiddenPinChanged(previous)
                Log.ui.warning("Couldn’t hide the pinned message: \(error.userMessage)")
            }
        }
    }
}
