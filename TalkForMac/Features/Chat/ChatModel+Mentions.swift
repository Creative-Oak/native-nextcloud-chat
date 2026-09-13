import Foundation

/// Mention autocomplete.
///
/// The detection and the `@"quoted id"` syntax live in `MentionComposer` in TalkCore, where
/// they are unit-tested; this is the part that talks to the server and drives the popover.
extension ChatModel {
    var isShowingMentionSuggestions: Bool {
        mentionQuery != nil && !mentionSuggestions.isEmpty
    }

    var canMention: Bool {
        conversation.canPostMessages && !conversation.isNoteToSelf
    }

    /// Called whenever the text or the caret moves.
    func refreshMentionQuery() {
        guard !isApplyingMention else { return }
        guard canMention, editing == nil else {
            dismissMentions()
            return
        }

        guard let query = MentionComposer.activeQuery(in: draftText, caret: caret) else {
            dismissMentions()
            return
        }

        // Same query as last time: leave the results alone rather than flickering them.
        if mentionQuery?.text == query.text, mentionQuery != nil {
            mentionQuery = query
            return
        }

        mentionQuery = query
        highlightedMentionIndex = 0
        scheduleMentionSearch(query.text)
    }

    private func scheduleMentionSearch(_ search: String) {
        mentionTask?.cancel()

        guard !search.isEmpty else {
            // A bare `@` shouldn't ask the server for the entire participant list.
            mentionSuggestions = []
            return
        }

        mentionTask = Task { [weak self] in
            // Debounced: typing "@alexander" is one request, not ten.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }

            // Typed: the only thing this block throws is a TalkError, and saying so gives
            // the catch a typed error instead of `any Error`.
            do throws(TalkError) {
                let results = try await self.session.chat.mentionSuggestions(
                    token: self.token,
                    search: search,
                    includeStatus: true
                )
                guard !Task.isCancelled else { return }
                // The query may have moved on while we were waiting.
                guard self.mentionQuery?.text == search else { return }
                self.mentionSuggestions = self.permitted(results)
                self.highlightedMentionIndex = 0
            } catch {
                // Autocomplete failing is not worth telling anyone about; they can type the
                // name out in full.
                Log.chat.debug("Mention lookup failed: \(error.userMessage)")
                self.mentionSuggestions = []
            }
        }
    }

    /// Hides `@all` where the server says only moderators may use it.
    private func permitted(_ suggestions: [MentionSuggestion]) -> [MentionSuggestion] {
        guard capabilities.supportsMentionPermissions,
              conversation.mentionPermissions == 1,
              !conversation.isModerator
        else { return suggestions }
        return suggestions.filter { !$0.isEveryone }
    }

    func moveMentionHighlight(by offset: Int) {
        guard !mentionSuggestions.isEmpty else { return }
        let next = highlightedMentionIndex + offset
        highlightedMentionIndex = min(max(next, 0), mentionSuggestions.count - 1)
    }

    func acceptHighlightedMention() {
        guard mentionSuggestions.indices.contains(highlightedMentionIndex) else { return }
        accept(mentionSuggestions[highlightedMentionIndex])
    }

    func accept(_ suggestion: MentionSuggestion) {
        guard let query = mentionQuery else { return }
        let result = MentionComposer.apply(suggestion, to: draftText, replacing: query)

        // The whole rewrite is one atomic step as far as detection is concerned: writing the
        // text and then moving the caret would otherwise re-detect the mention we just
        // completed and reopen the list on it.
        isApplyingMention = true
        dismissMentions()
        draftText = result.text
        caret = result.caret
        caretRequest = result.caret
        isApplyingMention = false
    }

    func dismissMentions() {
        mentionTask?.cancel()
        mentionTask = nil
        mentionQuery = nil
        mentionSuggestions = []
        highlightedMentionIndex = 0
    }
}
