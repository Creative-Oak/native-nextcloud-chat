import AppKit
import SwiftUI

/// ⌘P — Spotlight's shape over the window: a glass capsule to type into and a glass
/// panel of answers beneath it, with a gap between, the way Spotlight floats over the
/// desktop. Conversations, commands, people and messages, and Return does the thing.
struct CommandPaletteView: View {
    @Bindable var model: CommandPaletteModel
    /// How tall the panel may grow — a share of the window.
    var maxPanelHeight: CGFloat
    var onOpenConversation: (Conversation) -> Void
    var onOpenMessage: (MessageSearchHit) -> Void
    var onSeeAllMessages: (String) -> Void
    var onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 10) {
            field
            if !model.sections.isEmpty {
                panel
            }
        }
        .frame(width: 640)
        // The field takes focus as the palette appears, and is asked again once the
        // scale-and-fade has settled: a request made while the view is still coming in
        // is dropped.
        .defaultFocus($isFieldFocused, true)
        .onAppear {
            isFieldFocused = true
            installKeys()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                isFieldFocused = true
            }
        }
        .onDisappear {
            model.cancel()
            removeKeys()
        }
        .alert("Couldn't Start a Conversation", isPresented: Binding(get: { model.creationError != nil }, set: { _ in })) {
            Button("OK") {}
        } message: {
            Text(model.creationError ?? "")
        }
    }

    // MARK: - Keys
    //
    // Taken from the event stream rather than with `onKeyPress` or the field's
    // `onSubmit`: the field has the focus, and neither the arrows and Escape it did not
    // want nor the Return it did were reaching the handlers around it. A local monitor
    // sees every key-down in the window while the palette is up, keeps the ones that
    // steer it, and lets the rest — ⌘P among them, which is the menu's — go through.

    private static let escape: UInt16 = 53
    private static let upArrow: UInt16 = 126
    private static let downArrow: UInt16 = 125
    private static let returnKey: UInt16 = 36
    private static let keypadEnter: UInt16 = 76

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case Self.downArrow:
                if command { model.moveSection(1) } else { model.move(1) }
                return nil
            case Self.upArrow:
                if command { model.moveSection(-1) } else { model.move(-1) }
                return nil
            case Self.returnKey, Self.keypadEnter:
                choose()
                return nil
            case Self.escape:
                // Clears first, then closes: a mistyped query is cheap to fix.
                if model.query.isEmpty {
                    onDismiss()
                } else {
                    model.query = ""
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    // MARK: - The field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search Kvidr", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($isFieldFocused)
            if model.isCreating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .glass(.field, cornerRadius: 26)
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    // MARK: - The panel

    private var panel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.sections) { section in
                        header(section)
                        ForEach(section.rows) { row in
                            self.row(row)
                                .id(row.id)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: maxPanelHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.highlighted) { _, _ in
                if let row = model.highlightedRow {
                    proxy.scrollTo(row.id)
                }
            }
        }
        .glass(.panel, cornerRadius: 14)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }

    private func header(_ section: CommandPaletteModel.Section) -> some View {
        HStack(spacing: 8) {
            Text(section.kind.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if section.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .frame(width: 60)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func row(_ row: CommandPaletteModel.Row) -> some View {
        let isHighlighted = model.highlightedRow?.id == row.id
        return HStack(spacing: 10) {
            leading(for: row)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: row))
                    .lineLimit(1)
                if let secondary = secondary(for: row) {
                    Text(secondary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 8)
            trailing(for: row)
        }
        .foregroundStyle(row.isSelectable ? (isHighlighted ? .white : .primary) : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(isHighlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onTapGesture {
            guard row.isSelectable, let index = model.selectableRows.firstIndex(where: { $0.id == row.id }) else { return }
            model.highlighted = index
            choose()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelectable ? .isButton : [])
    }

    @ViewBuilder
    private func leading(for row: CommandPaletteModel.Row) -> some View {
        switch row {
        case .conversation(let conversation):
            AvatarView(conversation: conversation, size: 26)
        case .command(let command):
            Image(systemName: command.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.6), in: .circle)
        case .person(let entry):
            Image(systemName: entry.source.symbolName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.6), in: .circle)
        case .message(let hit):
            ActorAvatarView(actor: hit.actor, size: 26)
        case .seeAllMessages:
            Image(systemName: "arrow.right.circle")
                .font(.system(size: 16))
        case .noResults:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
        }
    }

    private func title(for row: CommandPaletteModel.Row) -> String {
        switch row {
        case .conversation(let c): c.displayName
        case .command(let c): c.title
        case .person(let p): p.label
        case .message(let m): m.title
        case .seeAllMessages: String(localized: "See all results for “\(model.trimmedQuery)”", comment: "Command palette: %@ is what was typed")
        case .noResults: String(localized: "No results for “\(model.trimmedQuery)”", comment: "Command palette: %@ is what was typed")
        }
    }

    private func secondary(for row: CommandPaletteModel.Row) -> String? {
        switch row {
        case .conversation(let c): ConversationPreview.text(for: c)
        case .command(let c): c.isEnabled ? nil : c.disabledReason
        case .person(let p): p.subline
        case .message(let m): m.snippet
        case .seeAllMessages, .noResults: nil
        }
    }

    @ViewBuilder
    private func trailing(for row: CommandPaletteModel.Row) -> some View {
        switch row {
        case .command(let command):
            if let keys = command.keys {
                Text(keys)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .opacity(0.7)
            }
        case .conversation(let conversation):
            if conversation.hasUnread {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
            }
            kindLabel(conversation.isOneToOne
                      ? String(localized: "Direct", comment: "Command palette row tag: a one-to-one conversation")
                      : String(localized: "Conversation", comment: "Command palette row tag: a group conversation"))
        case .person(let entry):
            kindLabel(entry.isGroupLike
                      ? String(localized: "Group", comment: "Command palette row tag: a group or team to start a conversation with")
                      : String(localized: "Person", comment: "Command palette row tag: a person to start a conversation with"))
        case .message(let hit):
            kindLabel(hit.threadID == nil
                      ? String(localized: "Message", comment: "Command palette row tag: a message found by search")
                      : String(localized: "Message · in thread", comment: "Command palette row tag: a message found by search, inside a thread"))
        case .seeAllMessages, .noResults:
            EmptyView()
        }
    }

    private func kindLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .opacity(0.6)
    }

    // MARK: - Choosing

    private func choose() {
        guard let row = model.highlightedRow else { return }
        switch row {
        case .conversation(let conversation):
            onOpenConversation(conversation)
        case .command(let command):
            onDismiss()
            command.perform()
        case .person(let entry):
            Task {
                if let conversation = await model.conversation(for: entry) {
                    onOpenConversation(conversation)
                }
            }
        case .message(let hit):
            onOpenMessage(hit)
        case .seeAllMessages:
            onSeeAllMessages(model.trimmedQuery)
        case .noResults:
            break
        }
    }
}
