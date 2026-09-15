import AppKit
import SwiftUI

/// ⇧⌘F — search everything the server remembers.
///
/// A sheet rather than a window: it is a step on the way to a message, not a place to
/// stay. Picking a result closes it and takes you there.
struct MessageSearchSheet: View {
    @Bindable var model: MessageSearchModel
    var onOpen: (MessageSearchHit) -> Void
    var onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 520)

        .task {
            isFieldFocused = true
            await model.checkAvailability()
        }
        .onDisappear { model.cancel() }
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search messages", text: $model.term)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isFieldFocused)
                    .onSubmit(open)
                    .disabled(!model.isAvailable)

                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.term.isEmpty {
                    Button {
                        model.term = ""
                        isFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }

            if model.canScopeToConversation {
                Picker("Search in", selection: $model.scope) {
                    Text(model.currentConversationName ?? "This Conversation")
                        .tag(MessageSearchModel.Scope.thisConversation)
                    Text("All Conversations")
                        .tag(MessageSearchModel.Scope.everywhere)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.isAvailable {
            unavailable
        } else if let error = model.error {
            ContentUnavailableView {
                Label("Couldn’t Search", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.userMessage)
            }
        } else if model.showsNoResults {
            ContentUnavailableView.search(text: model.term)
        } else if model.hits.isEmpty {
            ContentUnavailableView {
                Label("Search Messages", systemImage: "text.magnifyingglass")
            } description: {
                Text("Find anything said in your conversations, including history older than what this Mac has cached.")
            }
        } else {
            results
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Search Isn’t Available", systemImage: "magnifyingglass")
        } description: {
            Text("This Nextcloud server doesn’t offer Talk message search. Your administrator can enable it.")
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                        row(hit, isHighlighted: index == model.highlighted)
                            .id(hit.id)
                            .contentShape(.rect)
                            .onTapGesture {
                                model.highlighted = index
                                onOpen(hit)
                            }
                            .accessibilityAddTraits(.isButton)
                        Divider().padding(.leading, 52)
                    }

                    if model.hasMore {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            if model.isLoadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Show More Results")
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 12)
                    }
                }
            }
            .onChange(of: model.highlighted) { _, index in
                guard model.hits.indices.contains(index) else { return }
                proxy.scrollTo(model.hits[index].id)
            }
        }
    }

    private func row(_ hit: MessageSearchHit, isHighlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ActorAvatarView(actor: hit.actor, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hit.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(RelativeTimestamp.sidebar(hit.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(hit.snippet)
                    .font(.callout)
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.accentColor.opacity(0.16) : .clear)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !model.hits.isEmpty {
                Text("\(model.hits.count) result\(model.hits.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", role: .cancel, action: onClose)
                .keyboardShortcut(.cancelAction)
            Button("Go to Message", action: open)
                .keyboardShortcut(.defaultAction)

                .disabled(model.highlightedHit == nil)
        }
        .padding(12)
    }

    private func open() {
        guard let hit = model.highlightedHit else { return }
        onOpen(hit)
    }
}

extension MessageSearchHit {
    /// The author, for the avatar. The server sends the display name inside the rendered
    /// title ("Bob in Design"), which can't be split apart reliably, so the avatar falls
    /// back to the actor id — which is what it fetches by anyway.
    var actor: MessageActor {
        MessageActor(kind: MessageActor.Kind(rawValue: actorType), id: actorID)
    }
}
