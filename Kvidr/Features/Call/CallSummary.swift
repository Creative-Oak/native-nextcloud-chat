import AppKit
import Foundation
import FoundationModels
import Observation
import SwiftUI

/// Notes on a call — what was talked about, what was decided, who's doing what — written on
/// this Mac by Apple's language model from Live Captions' transcript. Talk's own call
/// summaries need an AI provider on the server; these need nothing but the Mac.
@MainActor
@Observable
final class CallSummary {
    enum State: Equatable {
        case idle
        case writing(String)
        case written(CallNotes)
        case failed(String)
    }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    /// Fewer lines than this is a call too short to summarize.
    static let minimumLines = 6

    @Generable
    struct CallNotes: Equatable {
        @Guide(description: "Two to five short bullet points on what was talked about.", .count(1...5))
        var summary: [String]
        @Guide(description: "What was agreed or decided, each in a short sentence. Empty if nothing was.", .maximumCount(5))
        var decisions: [String]
        @Guide(description: "Things someone said they or someone else would do. Empty if there were none.", .maximumCount(8))
        var actionItems: [ActionItem]

        /// The headings over what was decided and who's doing what, in the notes and the Markdown.
        static var decidedHeading: String { String(localized: "Decided", comment: "Heading in a call's notes: what was agreed or decided") }
        static var toDoHeading: String { String(localized: "To do", comment: "Heading in a call's notes: things people said they would do") }

        /// As Markdown, for the chat or the clipboard.
        func markdown(title: String) -> String {
            var parts = ["**\(title)**", summary.map { "- \($0)" }.joined(separator: "\n")]
            if !decisions.isEmpty {
                parts.append("**\(Self.decidedHeading)**\n" + decisions.map { "- \($0)" }.joined(separator: "\n"))
            }
            if !actionItems.isEmpty {
                parts.append("**\(Self.toDoHeading)**\n" + actionItems.map { "- [ ] \($0.who.isEmpty ? "" : "\($0.who): ")\($0.what)" }.joined(separator: "\n"))
            }
            return parts.joined(separator: "\n\n")
        }
    }

    @Generable
    struct ActionItem: Equatable {
        @Guide(description: "Who is to do it, by name as it was said; empty if nobody was named.")
        var who: String
        @Guide(description: "What is to be done, in a few words.")
        var what: String
    }

    private static let instructions = """
        You take notes on a call from its transcript. The transcript comes from live captions \\
        and has mistakes; read past them. Write in the language most of the call was in. Use \\
        only what was said: no guesses, no advice. Names as the speakers are labelled.
        """

    private static let partInstructions = """
        You take notes on one part of a longer call transcript, which comes from live captions \\
        and has mistakes. In at most eight short lines, note what was said, decided and promised, \\
        and by whom. Write in the language most of it was in. Only what was said.
        """

    /// Writes the notes from `lines` — in parts, for a long call.
    func write(from lines: [SummaryInput.Line], conversationName: String) {
        switch UnreadSummary.availability {
        case .available: break
        case .notYet(let reason):
            state = .failed(reason)
            return
        case .unsupported:
            state = .failed(String(localized: "Call summaries need Apple Intelligence, which this Mac doesn’t have."))
            return
        }
        guard lines.count >= Self.minimumLines else {
            state = .failed(String(localized: "Too little was said with Live Captions on to summarize."))
            return
        }
        let chunks = SummaryInput.chunks(lines)
        state = .writing(String(localized: "Reading the call…", comment: "Progress while call notes are written"))
        task?.cancel()
        task = Task { [weak self] in
            do {
                var material = chunks.first ?? ""
                if chunks.count > 1 {
                    var notes: [String] = []
                    for (index, chunk) in chunks.enumerated() {
                        self?.state = .writing(String(localized: "Reading part \(index + 1) of \(chunks.count)…", comment: "Progress while call notes are written: part 2 of 5 of the call"))
                        let session = LanguageModelSession(instructions: Self.partInstructions)
                        notes.append(try await session.respond(to: "Part \(index + 1) of the call:\n\n\(chunk)").content)
                    }
                    material = notes.joined(separator: "\n\n")
                }
                self?.state = .writing(String(localized: "Writing the notes…", comment: "Progress while call notes are written"))
                let session = LanguageModelSession(instructions: Self.instructions)
                let prompt = chunks.count > 1
                    ? "Notes on a call in “\(conversationName)”, part by part:\n\n\(material)"
                    : "Transcript of a call in “\(conversationName)”:\n\n\(material)"
                let response = try await session.respond(to: prompt, generating: CallNotes.self)
                self?.state = .written(response.content)
            } catch is CancellationError {
                return
            } catch {
                Log.ui.warning("Couldn’t summarize the call: \(error.localizedDescription)")
                self?.state = .failed(String(localized: "The call couldn’t be summarized."))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// A call's notes as the call screen shows them: what was talked about, what was decided, who's
/// doing what — and the ways to keep them: into the conversation's field to read over and send,
/// or onto the clipboard.
struct CallNotesView: View {
    let summary: CallSummary
    let title: String
    var onUseInChat: (String) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Call notes", systemImage: "apple.intelligence")
                .font(.system(size: 13, weight: .semibold))
            switch summary.state {
            case .idle:
                EmptyView()
            case .writing(let progress):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.white.opacity(0.75))
                }
                .font(.system(size: 12))
            case .failed(let reason):
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            case .written(let notes):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        bullets(notes.summary)
                        if !notes.decisions.isEmpty {
                            section(CallSummary.CallNotes.decidedHeading, notes.decisions)
                        }
                        if !notes.actionItems.isEmpty {
                            section(CallSummary.CallNotes.toDoHeading, notes.actionItems.map { $0.who.isEmpty ? $0.what : "\($0.who): \($0.what)" })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
                HStack(spacing: 10) {
                    Button("Put in Chat") { onUseInChat(notes.markdown(title: title)) }
                        .help("Into the conversation’s field, to read over and send")
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes.markdown(title: title), forType: .string)
                        copied = true
                    }
                }
                .controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(_ heading: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
            bullets(items)
        }
    }
}
