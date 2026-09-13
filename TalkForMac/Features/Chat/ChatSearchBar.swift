import SwiftUI

/// The find bar inside a conversation (⌥⌘F).
///
/// Floats over the transcript the way Safari's find bar does, rather than pushing the
/// conversation down — moving the thing you're reading while you look for something in it
/// is exactly wrong.
struct ChatSearchBar: View {
    @Bindable var model: ChatModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field

            if !model.searchMatches.isEmpty {
                Divider()
                results
            }
        }
        .frame(width: 380)
        .glass(.panel, cornerRadius: 12)
        .shadow(color: .black.opacity(0.14), radius: 14, y: 5)
        .onAppear { isFocused = true }
        .onExitCommand { model.isSearching = false }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in conversation", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { model.stepSearch(by: 1) }

            if !model.searchText.isEmpty {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 2) {
                Button { model.stepSearch(by: -1) } label: { Image(systemName: "chevron.up") }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button { model.stepSearch(by: 1) } label: { Image(systemName: "chevron.down") }
                    .keyboardShortcut("g", modifiers: .command)
            }
            .buttonStyle(.plain)
            .disabled(model.searchMatches.isEmpty)
            .foregroundStyle(model.searchMatches.isEmpty ? .tertiary : .secondary)

            Button { model.isSearching = false } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close (Escape)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        model.searchMatches.isEmpty
            ? "No matches"
            : "\(model.currentMatch + 1) of \(model.searchMatches.count)"
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.searchMatches.enumerated()), id: \.element.id) { index, match in
                    Button { model.jump(to: match) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(match.author)
                                    .font(.caption.weight(.medium))
                                Spacer(minLength: 0)
                                Text(match.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(match.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == model.currentMatch ? Color.accentColor.opacity(0.18) : .clear)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 260)
    }
}
