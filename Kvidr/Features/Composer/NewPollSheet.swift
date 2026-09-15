import SwiftUI

/// Creating a poll: the question, the options, and the two choices Talk offers about them.
struct NewPollSheet: View {
    let session: Session
    let token: String
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewPollModel

    init(session: Session, token: String, onCreated: @escaping () -> Void) {
        self.session = session
        self.token = token
        self.onCreated = onCreated
        _model = State(initialValue: NewPollModel(session: session, token: token))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Question") {
                    TextField("Question", text: $model.question, prompt: Text("What should we decide?"))
                        .labelsHidden()
                }

                Section("Options") {
                    ForEach($model.options.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            TextField("Option", text: $model.options[index], prompt: Text("Option \(index + 1)"))
                                .labelsHidden()

                            Button {
                                model.removeOption(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            // Two is the fewest a poll can be and still be a question.
                            .disabled(model.options.count <= 2)
                            .help("Remove this option")
                        }
                    }

                    Button("Add Option", systemImage: "plus") { model.addOption() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }

                Section {
                    Toggle("Allow more than one answer", isOn: $model.allowsMultipleAnswers)
                    Toggle("Hide results until the poll ends", isOn: $model.hidesResults)
                } footer: {
                    Text(model.hidesResults
                         ? "Nobody sees the counts, or who voted, until you end the poll."
                         : "Everyone sees the counts, and who voted for what, as votes come in.")
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 460, height: 520)
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(model.isCreating ? "Creating…" : "Create") {
                Task {
                    if await model.create() {
                        onCreated()
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate || model.isCreating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The sheet's state and the one call it makes.
@MainActor
@Observable
final class NewPollModel {
    var question = ""
    var options = ["", ""]
    var allowsMultipleAnswers = false
    var hidesResults = false
    private(set) var isCreating = false
    private(set) var error: String?

    private let session: Session
    private let token: String

    init(session: Session, token: String) {
        self.session = session
        self.token = token
    }

    /// Blank options are dropped rather than sent: an empty row is someone who tabbed past
    /// it, not an option called nothing.
    var filledOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filledOptions.count >= 2
    }

    func addOption() {
        options.append("")
    }

    func removeOption(at index: Int) {
        guard options.count > 2, options.indices.contains(index) else { return }
        options.remove(at: index)
    }

    func create() async -> Bool {
        guard canCreate, !isCreating else { return false }
        isCreating = true
        error = nil
        defer { isCreating = false }

        do {
            _ = try await session.polls.create(
                token: token,
                question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                options: filledOptions,
                resultMode: hidesResults ? .hiddenUntilClosed : .visible,
                // Zero is unlimited; one is a single answer. Talk has no notion of "up to
                // three", and neither does this sheet.
                maxVotes: allowsMultipleAnswers ? 0 : 1
            )
            return true
        } catch {
            self.error = error.userMessage
            return false
        }
    }
}
