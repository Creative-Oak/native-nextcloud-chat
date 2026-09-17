import Foundation

/// Whether the last thing somebody said is waiting on you.
///
/// Talk already flags a literal `@you`, which catches the easy half. The other half is
/// every message that plainly asks you something without spelling your name — "kan du nå
/// at kigge på den inden fredag?" — and in a working day those are most of what actually
/// needs answering.
enum Attention: Sendable, Hashable {
    /// Somebody is waiting on an answer.
    case asksYou
    /// Not obviously either way. The on-device model is allowed an opinion on these, and
    /// only these — which is what keeps the whole feature to one inference for a sidebar.
    case unclear
    /// Plainly nothing to do: an acknowledgement, a reaction in words, a thanks.
    case ignorable
}

/// Reads one message and says whether it is waiting on the reader.
///
/// A table again, and for the same reason: the sidebar has to be right the moment it is
/// painted, before any model has woken up, and on Macs where none ever will.
enum AttentionScanner {
    /// `mentionsYou` is Talk's own flag, which is authoritative and short-circuits the rest.
    static func read(_ text: String, mentionsYou: Bool = false) -> Attention {
        if mentionsYou { return .asksYou }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignorable }
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        // "ok", "tak!", "👍" — a whole class of message that exists to close a loop rather
        // than open one. Checked first, because "ok?" is an acknowledgement, not a question.
        if isAcknowledgement(folded) { return .ignorable }

        // A question mark is the strongest signal there is, and it survives translation.
        if trimmed.contains("?") { return .asksYou }

        if Self.requests.contains(where: { folded.contains($0) }) { return .asksYou }

        return .unclear
    }

    /// A message that closes a loop: short, and nothing in it but agreement.
    private static func isAcknowledgement(_ folded: String) -> Bool {
        guard folded.count <= 32 else { return false }

        // Punctuation comes off each word rather than off the ends of the message: "ja,
        // det lyder godt" is four words of agreement, and leaving the comma stuck to the
        // first one is what would make it look like something else.
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        let words = folded
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: punctuation) }
            .filter { !$0.isEmpty }

        guard !words.isEmpty else { return !folded.isEmpty }
        guard words.count <= 5 else { return false }
        // Every word has to be agreement, or not be a word at all — a thumbs-up is a whole
        // reply on its own. Emoji are tested by what they are made of rather than against
        // `CharacterSet.symbols`, whose membership is not the same on every platform.
        //
        // It is the "every" that does the work here: "ok tak" is an acknowledgement and
        // "ok men kan du lige" is not.
        return words.allSatisfy { word in
            acknowledgements.contains(word) || !word.contains { $0.isLetter || $0.isNumber }
        }
    }

    /// Ways of asking for something that don't need a question mark. Danish first, since
    /// that is what this app mostly carries.
    private static let requests: Set<String> = [
        // Danish
        "kan du", "kan i", "vil du", "vil i", "har du", "har i", "husk at", "husk lige",
        "send mig", "sender du", "giv mig", "giver du", "skal du", "skal vi",
        "ma jeg bede", "vaer sod at", "kunne du", "kunne i", "mangler stadig",
        "venter pa dig", "har brug for", "brug for din", "sig til nar", "sig lige til",
        "meld tilbage", "tag et kig", "kig lige", "se lige",
        // English
        "can you", "could you", "would you", "will you", "do you", "did you", "have you",
        "please ", "let me know", "get back to me", "waiting on you", "waiting for you",
        "need you to", "i need your", "remember to", "don't forget", "dont forget",
        "take a look", "have a look", "send me", "any update"
    ]

    private static let acknowledgements: Set<String> = [
        "ok", "okay", "okey", "fint", "super", "perfekt", "tak", "mange", "top", "godt",
        "ja", "jo", "nej", "javel", "modtaget", "noteret", "lyder", "det", "god", "yes",
        "no", "sure", "thanks", "thank", "you", "great", "perfect", "nice", "cool",
        "sounds", "good", "got", "it", "done", "same", "here"
    ]
}
