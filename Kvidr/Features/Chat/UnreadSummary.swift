import Foundation
import FoundationModels

/// A summary of the messages that came in while you were away, written on this Mac by
/// Apple's own language model — nothing leaves it. Offered when a conversation opens with a
/// lot unread; Talk's server-side summaries need an AI provider the server may not have.
@MainActor
@Observable
final class UnreadSummary {
    enum State: Equatable {
        /// Not asked for yet.
        case offered
        /// Being written; what there is of it so far.
        case writing(String)
        case written(String)
        case failed(String)
    }

    /// Whether this Mac can summarize at all, and if not, whether the user can do something
    /// about it.
    enum Availability: Equatable {
        case available
        /// Apple Intelligence is off, or its model is still downloading.
        case notYet(String)
        /// This Mac can't run it.
        case unsupported
    }

    static var availability: Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .notYet("Turn on Apple Intelligence in System Settings to summarize.")
        case .unavailable(.modelNotReady):
            return .notYet("Apple Intelligence is still getting ready. Try again in a little while.")
        case .unavailable:
            return .unsupported
        }
    }

    /// How many messages it is about: the unread ones, or — asked for with nothing unread —
    /// the latest.
    let unreadCount: Int
    let isRecent: Bool
    private(set) var state: State = .offered
    /// How many messages the summary covers — the newest, when they didn't all fit.
    private(set) var coveredCount = 0

    /// What it's a summary of, when it isn't the unread or the latest messages — "the thread
    /// “Launch”", "the last week".
    let subject: String?

    private let conversationName: String
    private let lines: () -> [SummaryInput.Line]
    private var task: Task<Void, Never>?

    /// `subject` set: everything `lines` gives is summarized, in chunks when it doesn't fit the
    /// model at once. Without it, the newest that fit.
    init(unreadCount: Int, isRecent: Bool = false, subject: String? = nil, conversationName: String, lines: @escaping () -> [SummaryInput.Line]) {
        self.unreadCount = unreadCount
        self.isRecent = isRecent
        self.subject = subject
        self.conversationName = conversationName
        self.lines = lines
    }

    private static let instructions = """
        You help someone catch up on a group chat they were away from. Summarize the messages \
        in two to five short bullet points, each starting with "• ". Write in the language \
        most of the messages are written in. Say who said, asked or decided what when it \
        matters. Use only what the messages say. No heading, no introduction, no closing remark.
        """

    /// Notes on one part of a long stretch, to be summarized with the others.
    private static let noteInstructions = """
        You take notes on one part of a longer group chat. List what was said, asked and \
        decided, and by whom, in at most six short lines. Write in the language most of the \
        messages are written in. Use only what the messages say. No heading, no introduction.
        """

    func write() {
        if case .notYet(let reason) = Self.availability {
            state = .failed(reason)
            return
        }
        if subject != nil {
            writeInParts()
            return
        }
        let (transcript, included) = SummaryInput.transcript(lines())
        guard included > 0 else {
            state = .failed("There’s nothing here to summarize yet.")
            return
        }
        coveredCount = included
        state = .writing("")
        let prompt = "Messages in “\(conversationName)”, oldest first:\n\n\(transcript)"
        task?.cancel()
        task = Task { [weak self] in
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                var latest = ""
                for try await snapshot in session.streamResponse(to: prompt) {
                    latest = snapshot.content
                    self?.state = .writing(latest)
                }
                self?.state = .written(latest.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                self?.state = .failed(Self.message(for: error))
            } catch {
                self?.state = .failed("The summary couldn’t be written: \(error.localizedDescription)")
            }
        }
    }

    /// A thread, a day, a week: more than the model takes in at once. Each part is noted
    /// down, then the notes summarized — the summary streams in as before.
    private func writeInParts() {
        let all = lines()
        let chunks = SummaryInput.chunks(all)
        guard !chunks.isEmpty else {
            state = .failed("There’s nothing here to summarize.")
            return
        }
        coveredCount = all.count
        state = .writing("")
        let name = conversationName
        task?.cancel()
        task = Task { [weak self] in
            do {
                var notes: [String] = []
                if chunks.count == 1 {
                    notes = chunks
                } else {
                    for (index, chunk) in chunks.enumerated() {
                        self?.state = .writing("Reading part \(index + 1) of \(chunks.count)…")
                        let session = LanguageModelSession(instructions: Self.noteInstructions)
                        let response = try await session.respond(to: "Part \(index + 1) of the messages in “\(name)”:\n\n\(chunk)")
                        notes.append(response.content)
                    }
                }
                let material = chunks.count == 1
                    ? "Messages in “\(name)”, oldest first:\n\n\(notes[0])"
                    : "Notes on the messages in “\(name)”, part by part, oldest first:\n\n\(notes.joined(separator: "\n\n"))"
                let session = LanguageModelSession(instructions: Self.instructions)
                var latest = ""
                for try await snapshot in session.streamResponse(to: material) {
                    latest = snapshot.content
                    self?.state = .writing(latest)
                }
                self?.state = .written(latest.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError {
                return
            } catch let error as LanguageModelSession.GenerationError {
                self?.state = .failed(Self.message(for: error))
            } catch {
                self?.state = .failed("The summary couldn’t be written: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal:
            "Apple Intelligence declined to summarize these messages."
        case .unsupportedLanguageOrLocale:
            "Apple Intelligence can’t summarize messages in this language yet."
        case .rateLimited, .concurrentRequests:
            "Apple Intelligence is busy. Try again in a moment."
        case .assetsUnavailable:
            "Apple Intelligence is still getting ready. Try again in a little while."
        default:
            "The summary couldn’t be written."
        }
    }
}
