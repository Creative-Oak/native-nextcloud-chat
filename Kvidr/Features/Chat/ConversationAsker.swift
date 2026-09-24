import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Questions about a conversation — "what did Anna say about the invoice?" — answered on this
/// Mac by Apple's language model, from the conversation itself: it searches the messages, as
/// often as it needs, with a tool that looks through what's loaded here and through
/// Nextcloud's own search of the whole history. The answer says which messages it rests on,
/// and those open with a click.
@MainActor
@Observable
final class ConversationAsker {
    enum State: Equatable {
        case idle
        case thinking
        case answered(String, sources: [Source])
        case failed(String)
    }

    /// A message the answer rests on.
    struct Source: Identifiable, Equatable, Sendable {
        let id: Int
        let author: String
        let date: Date
    }

    var question = ""
    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    /// The messages the model can see, one line each.
    struct Snippet: Sendable {
        let id: Int
        let author: String
        let date: Date
        let text: String

        var line: String {
            "[#\(id)] \(author), \(date.formatted(date: .abbreviated, time: .shortened)): \(text)"
        }
    }

    private static let instructions = """
        You answer questions about a chat conversation, using only its messages. Look things \\
        up with the searchMessages tool — as often as you need, with different words — before \\
        saying something isn't there. Answer briefly, in the language of the question. After \\
        each fact, add the id of the message it comes from, like [#123]. If the messages don't \\
        answer the question, say so plainly.
        """

    /// `recent`: the latest messages, which the model sees from the start. `search`: finds
    /// more — loaded ones and the server's — for a query.
    func ask(conversationName: String, recent: [Snippet], search: @escaping @Sendable (String) async -> [Snippet]) {
        let question = self.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        switch UnreadSummary.availability {
        case .available: break
        case .notYet(let reason):
            state = .failed(reason)
            return
        case .unsupported:
            state = .failed(String(localized: "Asking needs Apple Intelligence, which this Mac doesn’t have."))
            return
        }
        state = .thinking
        task?.cancel()
        let seen = SeenSnippets()
        seen.add(recent)
        let tool = SearchMessagesTool { query in
            let found = await search(query)
            seen.add(found)
            return found
        }
        let prompt = """
            Conversation: “\(conversationName)”. Its latest messages, oldest first:
            \(Self.context(recent))

            Question: \(question)
            """
        task = Task { [weak self] in
            let session = LanguageModelSession(tools: [tool], instructions: Self.instructions)
            do {
                let answer = try await session.respond(to: prompt).content
                let (text, ids) = AnswerCitations.parse(answer)
                let sources = ids.compactMap { seen.source(for: $0) }
                self?.state = .answered(text, sources: sources)
            } catch is CancellationError {
                return
            } catch {
                Log.ui.warning("Couldn’t answer a question about the conversation: \(error.localizedDescription)")
                self?.state = .failed(String(localized: "Apple Intelligence couldn’t answer that."))
            }
        }
    }

    /// The newest messages that fit in about 2 400 characters, oldest first — room enough
    /// left for the tool's results and the answer.
    private static func context(_ recent: [Snippet]) -> String {
        var lines: [String] = []
        var used = 0
        for snippet in recent.reversed() {
            let line = snippet.line
            guard used + line.count <= 2_400 else { break }
            lines.append(line)
            used += line.count + 1
        }
        return lines.reversed().joined(separator: "\n")
    }

    func reset() {
        task?.cancel()
        state = .idle
        question = ""
    }
}

/// What the model has been shown, so the messages it cites can be named and opened.
private final class SeenSnippets: @unchecked Sendable {
    private let lock = NSLock()
    private var snippets: [Int: ConversationAsker.Snippet] = [:]

    func add(_ found: [ConversationAsker.Snippet]) {
        lock.withLock { for snippet in found { snippets[snippet.id] = snippet } }
    }

    func source(for id: Int) -> ConversationAsker.Source? {
        lock.withLock { snippets[id].map { ConversationAsker.Source(id: $0.id, author: $0.author, date: $0.date) } }
    }
}

/// The model's way into the conversation: words in, matching messages out.
private struct SearchMessagesTool: Tool {
    let name = "searchMessages"
    let description = "Searches this conversation's messages for words, and returns the matching messages with their id, author, date and text."

    @Generable
    struct Arguments {
        @Guide(description: "One to three words to look for, as they would be written in the messages.")
        var query: String
    }

    let search: @Sendable (String) async -> [ConversationAsker.Snippet]

    func call(arguments: Arguments) async throws -> String {
        let found = await search(arguments.query)
        guard !found.isEmpty else { return "No messages match “\(arguments.query)”." }
        return found.map(\.line).joined(separator: "\n")
    }
}

/// Over the conversation: the question, and then the answer with the messages it rests on.
struct AskBar: View {
    let asker: ConversationAsker
    var onAsk: () -> Void
    var onOpen: (Int) -> Void
    var onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "apple.intelligence")
                    .foregroundStyle(.tint)
                TextField("Ask about this conversation", text: Binding(get: { asker.question }, set: { asker.question = $0 }))
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(onAsk)
                if asker.state == .thinking {
                    ProgressView().controlSize(.small)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            switch asker.state {
            case .idle, .thinking:
                EmptyView()
            case .failed(let reason):
                Text(reason).foregroundStyle(.secondary)
            case .answered(let text, let sources):
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(sources) { source in
                                Button { onOpen(source.id) } label: {
                                    Label("\(source.author), \(source.date.formatted(date: .abbreviated, time: .omitted))", systemImage: "text.bubble")
                                        .font(.system(size: 11))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.quaternary, in: .capsule)
                                }
                                .buttonStyle(.plain)
                                .help("Show this message")
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .glass(.panel, cornerRadius: 12)
        .onAppear { isFocused = true }
    }
}
