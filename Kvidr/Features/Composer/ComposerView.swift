import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The compose area: reply/edit context, the text field, and the send affordance.
struct ComposerView: View {
    @Bindable var model: ChatModel
    @Binding var isFocused: Bool

    @Environment(\.preferences) private var preferences
    @State private var height: CGFloat = ComposerTextView.minimumHeight
    @State private var isShowingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var isShowingNewPoll = false

    var body: some View {
        VStack(spacing: 0) {
            AttachmentTray(queue: model.attachments)

            if let replyingTo = model.replyingTo {
                ComposerContextBar(
                    symbol: "arrowshape.turn.up.left",
                    title: "Replying to \(replyingTo.actor.resolvedDisplayName)",
                    detail: model.content(for: replyingTo).preview,
                    onCancel: { model.cancelReply() }
                )
            } else if model.editing != nil {
                ComposerContextBar(
                    symbol: "pencil",
                    title: "Editing message",
                    detail: nil,
                    onCancel: { model.cancelEdit() }
                )
            }

            if model.conversation.canPostMessages {
                editor
            } else {
                unavailableNotice
            }
        }
        // No bar. The composer is floating chrome now: the transcript slides under it and
        // shows through the glass, which is what the material is for.
        .overlay(alignment: .bottomLeading) { mentionSuggestions }
    }

    private var editor: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if model.attachments.canAttach {
                Menu {
                    Button("Photos…", systemImage: "photo") { isShowingPhotos = true }
                    Button("Files…", systemImage: "folder") { chooseFiles() }
                        .keyboardShortcut("a", modifiers: [.command, .shift])
                    if model.capabilities.supportsPolls {
                        Divider()
                        Button("Poll…", systemImage: "chart.bar.doc.horizontal") { isShowingNewPoll = true }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: GlassMetrics.control, height: GlassMetrics.control)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                // The glass drawn by hand, as the other round controls draw theirs.
                // `.buttonStyle(.glass)` on a menu never painted the circle at all, so
                // the plus sat there as a bare glyph beside a fielded text box.
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .glassCircle()
                .help("Add an attachment")
                .accessibilityLabel("Add an Attachment")
            }

            field

            // The system emoji palette, which inserts straight into the field — the
            // same thing Messages' smiley opens. The focus is moved first, and the
            // palette asked for on the next turn, so it lands in this field rather than
            // in whatever had focus a moment ago.
            Button {
                isFocused = true
                Task { @MainActor in NSApplication.shared.orderFrontCharacterPalette(nil) }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: GlassMetrics.control, height: GlassMetrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("Emoji")
            .accessibilityLabel("Emoji")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Apple's own picker, out of process: the user chooses inside it and only the chosen
        // items cross over, so a sandboxed app needs no library permission, no usage string
        // and no entitlement to send one photo. `PHPhotoLibrary` would want all three, and
        // would ask for the whole library to do it.
        .photosPicker(
            isPresented: $isShowingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: nil,
            // Messages' Fotos shows both, and the menu item would be a lie otherwise.
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: pickedPhotos) { _, picked in
            guard !picked.isEmpty else { return }
            pickedPhotos = []
            Task { await stage(picked) }
        }
        .sheet(isPresented: $isShowingNewPoll) {
            NewPollSheet(session: model.session, token: model.conversation.token) {
                // Nothing to insert here: creating a poll posts the message itself, and the
                // sync loop brings it back like anyone else's.
            }
        }
    }

    /// Copies what Photos handed over into the queue.
    ///
    /// Originals, unconverted — HEIC included. Nextcloud renders previews server-side, so a
    /// recipient sees the picture whatever they are on; re-encoding everyone's photos a
    /// generation down to save the rare case of someone downloading the original on an old
    /// system is a bad trade.
    private func stage(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            do {
                guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else { continue }
                urls.append(picked.url)
            } catch {
                Log.chat.warning("Couldn’t read a photo from the picker: \(error.localizedDescription)")
            }
        }
        guard !urls.isEmpty else { return }
        model.attachments.enqueue(urls: urls)
    }

    /// Text, character count and send, all inside one glass capsule — the field is a
    /// single control rather than a row of parts spread across the window.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ComposerTextView(
                text: $model.draftText,
                isFocused: $isFocused,
                measuredHeight: $height,
                caret: $model.caret,
                caretRequest: $model.caretRequest,
                placeholder: placeholder,
                isEnabled: true,
                sendsOnReturn: preferences?.sendsOnReturn ?? true,
                isSuggesting: model.isShowingMentionSuggestions,
                onSubmit: { model.send() },
                onCancel: { cancelContext() },
                onEditPrevious: { model.beginEditingLatestOwnMessage() },
                onMoveSuggestion: { model.moveMentionHighlight(by: $0) },
                onAcceptSuggestion: { model.acceptHighlightedMention() },
                onPasteImage: { image in
                    guard model.attachments.canAttach else { return }
                    model.attachments.enqueuePastedImage(image)
                },
                onPasteFiles: { urls in
                    guard model.attachments.canAttach else { return }
                    model.attachments.enqueue(urls: urls)
                }
            )
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if model.draftText.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .allowsHitTesting(false)
                }
            }

            VStack(alignment: .trailing, spacing: 2) {
                if let remaining = model.remainingCharacters {
                    Text("\(remaining)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(remaining < 0 ? .red : .secondary)
                }
                Button(action: { model.send() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.accentColor)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help(sendHelp)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        // Never shorter than the round buttons beside it: the three read as one band.
        .frame(minHeight: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
    }

    private var unavailableNotice: some View {
        HStack {
            Image(systemName: "lock")
            Text(model.conversation.isFormerOneToOne
                 ? "This person’s account was deleted. You can still read the conversation."
                 : "You don’t have permission to post in this conversation.")
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glass(.panel, cornerRadius: 14)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var placeholder: String {
        model.editing != nil ? "Edit message" : "Message \(model.conversation.displayName)"
    }

    private var sendHelp: String {
        (preferences?.sendsOnReturn ?? true)
            ? "Send (Return · Shift-Return for a new line)"
            : "Send (⌘Return)"
    }

    /// Floats above the composer rather than pushing it down, so the text you're typing
    /// doesn't move while you're typing it.
    @ViewBuilder
    private var mentionSuggestions: some View {
        if model.isShowingMentionSuggestions {
            MentionSuggestionList(
                suggestions: model.mentionSuggestions,
                highlighted: model.highlightedMentionIndex,
                onPick: { model.accept($0) }
            )
            .padding(.leading, 12)
            .offset(y: -(height + 24))
        }
    }

    /// An open panel rather than a custom picker, because the system one already knows about
    /// tags, recents, iCloud and everything else. Photos has its own picker now, so this one
    /// no longer filters to images.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to \(model.conversation.displayName)"

        guard panel.runModal() == .OK else { return }
        model.attachments.enqueue(urls: panel.urls)
    }

    private func cancelContext() {
        if model.isShowingMentionSuggestions {
            model.dismissMentions()
            return
        }
        if model.editing != nil {
            model.cancelEdit()
        } else if model.replyingTo != nil {
            model.cancelReply()
        }
    }
}

/// The strip above the field showing what you're replying to or editing.
private struct ComposerContextBar: View {
    let symbol: String
    let title: String
    let detail: String?
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Cancel (Escape)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(.panel, cornerRadius: 12)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

private struct PreferencesKey: EnvironmentKey {
    static let defaultValue: Preferences? = nil
}

extension EnvironmentValues {
    var preferences: Preferences? {
        get { self[PreferencesKey.self] }
        set { self[PreferencesKey.self] = newValue }
    }
}

/// A picked photo or video, copied to a file on the way out of Photos.
///
/// A `FileRepresentation` rather than `loadTransferable(type: Data.self)`: the `Data` route
/// holds a four-gigabyte video in memory before a byte of it is uploaded, and the upload
/// path wants a file anyway.
private struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            // The received file is deleted as soon as this returns, so it is copied out —
            // into a directory of its own, since two picks can share a name.
            let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedPhoto(url: destination)
        }
    }
}
