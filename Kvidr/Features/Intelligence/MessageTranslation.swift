import Foundation
import Observation
import Translation

/// Translating a message into the language you read in.
///
/// Not the language model — Apple's `Translation` framework, which is the right tool and a
/// much smaller one. It runs on this Mac, it does not need Apple Intelligence at all, and
/// the first time a language is used macOS offers to download it and shows its own
/// progress.
///
/// A team split across two languages is the ordinary case this app is used in, and a
/// message you can't read is the one thing a chat client really can't leave you with.
@MainActor
@Observable
final class MessageTranslationModel {
    enum State: Equatable {
        case working
        case done(Translated)
        case failed(String)
    }

    /// Keyed by message id. The original is never replaced — see `Translated`.
    private(set) var states: [Int: State] = [:]

    /// What the `.translationTask` modifier in the transcript is currently working on.
    /// Setting this is what starts a translation; the view does the rest.
    private(set) var pending: Pending?

    struct Pending: Equatable {
        var messageID: Int
        var text: String
        /// Changed on every request so an identical repeat still triggers the task.
        var attempt: Int
    }

    private var attempts = 0

    /// Whether this message already has a translation on screen.
    func state(for messageID: Int) -> State? { states[messageID] }

    /// Asked for from the message menu. Translating a second time takes it away again —
    /// the menu item is a toggle, because that is what people expect of one.
    func toggle(messageID: Int, text: String) {
        if states[messageID] != nil {
            states[messageID] = nil
            if pending?.messageID == messageID { pending = nil }
            return
        }
        attempts += 1
        states[messageID] = .working
        pending = Pending(messageID: messageID, text: text, attempt: attempts)
    }

    /// Called by the view once the framework has answered.
    func finished(messageID: Int, with result: Result<Translated, Error>) {
        switch result {
        case .success(let translated):
            // A translation identical to the original is the framework telling us it was
            // already in this language. Saying so is more use than showing it twice.
            if translated.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == translated.original.trimmingCharacters(in: .whitespacesAndNewlines) {
                states[messageID] = .failed("Already in your language")
            } else {
                states[messageID] = .done(translated)
            }
        case .failure(let error):
            Log.ui.warning("Couldn’t translate a message: \(error.localizedDescription)")
            states[messageID] = .failed("Couldn’t translate this")
        }
        if pending?.messageID == messageID { pending = nil }
    }

    /// The conversation changed, or the user signed out.
    func clear() {
        states = [:]
        pending = nil
    }
}

/// A message in the reader's own language, beside the words that were actually sent.
struct Translated: Sendable, Equatable {
    var text: String
    var original: String
    /// What it was translated from, named in the reader's language. Nil when the framework
    /// didn't say — it detects the source itself and isn't obliged to report it.
    var sourceLanguage: String?
}
