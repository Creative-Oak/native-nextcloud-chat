import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Conversations in Spotlight: their names, and what was said last — except in sensitive
/// ones, whose words stay out of it as they stay out of notifications. Picking one in
/// Spotlight opens it here. Kept up to date as the sidebar syncs, a moment after it settles.
@MainActor
final class SpotlightIndex {
    static let activityType = CSSearchableItemActionType
    private static let domain = "app.kvidr.mac.conversations"

    /// What each conversation was indexed as, so an unchanged one isn't sent again.
    private var indexed: [String: String] = [:]
    private var pending: Task<Void, Never>?
    private let parser = MessageContentParser(currentUserID: "", markdownEnabled: false)

    func update(_ conversations: [Conversation]) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            await self.index(conversations.filter { !$0.isBreakoutRoom })
        }
    }

    /// Signed out: nothing of the account stays searchable.
    func removeAll() {
        pending?.cancel()
        indexed = [:]
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in }
    }

    static func token(from activity: NSUserActivity) -> String? {
        activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }

    private func index(_ conversations: [Conversation]) async {
        var items: [CSSearchableItem] = []
        var now: [String: String] = [:]
        for conversation in conversations {
            let last = conversation.isSensitive ? "" : conversation.lastMessage.map { parser.parse($0).preview } ?? ""
            let signature = "\(conversation.displayName)\u{1}\(last)\u{1}\(conversation.isArchived)"
            now[conversation.token] = signature
            guard indexed[conversation.token] != signature else { continue }
            let attributes = CSSearchableItemAttributeSet(contentType: .message)
            attributes.title = conversation.displayName
            attributes.displayName = conversation.displayName
            attributes.contentDescription = last.isEmpty ? nil : String(last.prefix(300))
            attributes.lastUsedDate = conversation.lastActivity
            attributes.keywords = ["kvidr", "Talk", "Nextcloud"]
            let item = CSSearchableItem(uniqueIdentifier: conversation.token, domainIdentifier: Self.domain, attributeSet: attributes)
            // Archived ones are still findable, lower down.
            item.isUpdate = indexed[conversation.token] != nil
            items.append(item)
        }
        let gone = Set(indexed.keys).subtracting(now.keys)
        indexed = now
        let index = CSSearchableIndex.default()
        if !items.isEmpty {
            do { try await index.indexSearchableItems(items) } catch {
                Log.ui.info("Spotlight didn’t take the conversations: \(error.localizedDescription)")
            }
        }
        if !gone.isEmpty {
            try? await index.deleteSearchableItems(withIdentifiers: Array(gone))
        }
    }
}
