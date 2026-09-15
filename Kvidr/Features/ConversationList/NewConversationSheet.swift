import AppKit
import SwiftUI

/// ⌘N — start a conversation.
///
/// Three kinds, because Talk has three that matter: a direct message, a private group, and
/// an open conversation anyone on the server can find. The people search is Nextcloud's own
/// autocomplete, so it finds exactly who the server thinks you can talk to.
struct NewConversationSheet: View {
    let session: Session
    var onCreated: (Conversation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: NewConversationModel

    init(session: Session, onCreated: @escaping (Conversation) -> Void) {
        self.session = session
        self.onCreated = onCreated
        _model = State(initialValue: NewConversationModel(session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            // No title band and no dividers: a Mac sheet has no title bar, and is identified
            // by what it holds and the window behind it. A bold heading over a rule is a
            // phone modal's chrome.
            Form {
                Section {
                    Picker("Kind", selection: $model.kind) {
                        ForEach(NewConversationModel.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if model.kind != .direct {
                    Section {
                        TextField("Name", text: $model.name, prompt: Text("Design review"))
                    }
                }

                if model.kind == .publicRoom {
                    Section {
                        SecureField("Password", text: $model.password, prompt: Text("Leave empty for no password"))
                    } footer: {
                        Text("Anyone with the link can join. A password is optional.")
                    }
                }

                peopleSection
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 460, height: 520)
    }

    @ViewBuilder
    private var peopleSection: some View {
        Section(model.kind == .direct ? "Person" : "Add people") {
            // A real text field: its focus ring and its bezel are the system's, rather than
            // a magnifier glyph and a pill drawn by hand.
            TextField("Search", text: $model.search, prompt: Text("Search people, groups and teams"))
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if model.isSearching {
                        ProgressView().controlSize(.small).padding(.trailing, 6)
                    }
                }

            if !model.selected.isEmpty {
                selectedChips
            }

            if model.results.isEmpty && model.search.count >= 2 && !model.isSearching {
                Text("No matches.")
                    .foregroundStyle(.secondary)
            }

            // Rows of the form, so they get its own insets and separators rather than a
            // stack of hand-padded buttons.
            ForEach(model.results) { entry in
                Button {
                    model.toggle(entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: entry.source.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.label).lineLimit(1)
                            if let subline = entry.subline, !subline.isEmpty {
                                Text(subline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if model.isSelected(entry) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var selectedChips: some View {
        GlassEffectContainer(spacing: GlassSpacing.merging) {
            // A wrapping row of the people picked so far.
            FlowLayout(spacing: 6) {
                ForEach(model.selected) { entry in
                    Button { model.toggle(entry) } label: {
                        HStack(spacing: 4) {
                            Text(entry.label).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .glass(.chip)
                }
            }
        }
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
                    if let conversation = await model.create() { onCreated(conversation) }
                }
            }
            // No explicit style: `defaultAction` is what makes AppKit draw the window's
            // default button, and it draws it the way every other Mac dialog does.
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCreate || model.isCreating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// The sheet's state and the one network call it makes.
@MainActor
@Observable
final class NewConversationModel {
    enum Kind: String, CaseIterable, Identifiable {
        case direct, group, publicRoom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: "Direct"
            case .group: "Group"
            case .publicRoom: "Open"
            }
        }
    }

    var kind: Kind = .direct {
        didSet { if kind == .direct { selected = Array(selected.prefix(1)) } }
    }
    var name = ""
    var password = ""
    var search = "" { didSet { scheduleSearch() } }

    private(set) var results: [DirectoryEntry] = []
    private(set) var selected: [DirectoryEntry] = []
    private(set) var isSearching = false
    private(set) var isCreating = false
    private(set) var error: String?

    private let session: Session
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(session: Session) {
        self.session = session
    }

    var canCreate: Bool {
        switch kind {
        case .direct: selected.first?.source == .users
        case .group, .publicRoom: !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func isSelected(_ entry: DirectoryEntry) -> Bool {
        selected.contains(entry)
    }

    func toggle(_ entry: DirectoryEntry) {
        if let index = selected.firstIndex(of: entry) {
            selected.remove(at: index)
        } else if kind == .direct {
            // A direct conversation is with exactly one person.
            selected = [entry]
        } else {
            selected.append(entry)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let term = search
        guard term.count >= 2 else {
            results = []
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            defer { self.isSearching = false }
            do throws(TalkError) {
                // A direct conversation can only be with a person, so don't offer groups.
                let types = self.kind == .direct ? [0] : [0, 1, 7]
                let found = try await self.session.directory.search(term, shareTypes: types)
                guard !Task.isCancelled, self.search == term else { return }
                self.results = found
            } catch {
                self.results = []
                self.error = error.userMessage
            }
        }
    }

    /// Creates the conversation, then invites anyone else who was picked.
    func create() async -> Conversation? {
        guard canCreate else { return nil }
        isCreating = true
        defer { isCreating = false }
        error = nil

        do throws(TalkError) {
            let request: NewConversation
            switch kind {
            case .direct:
                guard let person = selected.first else { return nil }
                request = .oneToOne(with: person.identifier)
            case .group:
                request = .group(named: name.trimmingCharacters(in: .whitespaces), inviting: selected.first)
            case .publicRoom:
                request = .publicRoom(
                    named: name.trimmingCharacters(in: .whitespaces),
                    password: password.isEmpty ? nil : password
                )
            }

            let conversation = try await session.conversations.create(request).conversation

            // `invite` carries at most one person, so anyone else picked is added after the
            // fact. A group already invited `selected.first` via `invite`; an open room
            // invited nobody, so everyone picked still needs adding.
            let remaining: [DirectoryEntry] = switch kind {
            case .direct: []
            case .group: Array(selected.dropFirst())
            case .publicRoom: selected
            }
            for entry in remaining {
                try? await session.participants.add(entry, to: conversation.token)
            }

            return conversation
        } catch {
            self.error = error.userMessage
            return nil
        }
    }
}
