import SwiftUI

/// The **To:** band, which lives in the toolbar rather than under it.
///
/// Messages puts it on the title bar's own line, full width, with nothing else beside it —
/// so while a draft is open the compose and search buttons stand down and this takes the
/// row. See `RootView.detailToolbar`.
struct RecipientBand: View {
    @Bindable var draft: ConversationDraft
    /// A plain binding, not `@FocusState`: focus has to reach an `NSTextField`, which a
    /// `FocusState` cannot do.
    @Binding var isFocused: Bool

    @State private var isBrowsingContacts = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("To:")
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(draft.recipients) { recipient in
                    Button { draft.remove(recipient) } label: {
                        HStack(spacing: 4) {
                            Text(recipient.label).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .glass(.chip)
                }

                RecipientTextField(
                    text: $draft.search,
                    isFocused: $isFocused,
                    prompt: draft.recipients.isEmpty ? "Name, group or team" : "",
                    onBackspaceIntoChips: {
                        guard !draft.recipients.isEmpty else { return false }
                        draft.removeLastRecipient()
                        return true
                    },
                    onMove: { delta in
                        guard !draft.results.isEmpty else { return false }
                        draft.moveHighlight(by: delta)
                        return true
                    },
                    onAccept: { draft.acceptHighlighted() },
                    onCancel: {
                        guard !draft.results.isEmpty else { return false }
                        draft.clearSearch()
                        return true
                    }
                )
                .frame(minWidth: 140, minHeight: 20)
            }
            // Takes the slack, so the band's chips stay left and the globe and + sit at the
            // trailing edge rather than everything bunching in the middle of a wide band.
            .frame(maxWidth: .infinity, alignment: .leading)

            if draft.isSearching { ProgressView().controlSize(.small) }

            // Public rather than private. A one-to-one cannot be public, so switching this on
            // makes even a single recipient an open conversation.
            //
            // A `Toggle` in `.button` style rather than a switch: still a toggle to VoiceOver
            // and the keyboard, but wearing the app's own glass — a pill that tints with the
            // accent when it is on, like a reaction that includes you.
            Toggle(isOn: $draft.isOpen) {
                Label("Open", systemImage: "globe")
                    .font(.callout)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .glass(draft.isOpen ? .selectedChip : .chip)
            .foregroundStyle(draft.isOpen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .help("Anyone on the server can find and join this conversation")

            Button { isBrowsingContacts = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("Browse contacts")
            .accessibilityLabel("Browse Contacts")
            .popover(isPresented: $isBrowsingContacts, arrowEdge: .bottom) {
                ContactBrowser(draft: draft)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: GlassMetrics.control)
        .glass(.field, cornerRadius: GlassMetrics.control / 2)
    }
}

/// What the + opens: everyone the server will list, without typing.
///
/// Nextcloud has no contacts endpoint of its own to browse — `core/autocomplete/get` is the
/// only listing there is, and it happens to accept an empty term. What it cannot tell us is
/// *why* it answered with nothing, so an empty result says both things it could mean.
private struct ContactBrowser: View {
    @Bindable var draft: ConversationDraft

    var body: some View {
        VStack(spacing: 0) {
            if draft.isBrowsingContacts {
                ProgressView().controlSize(.small).padding(24)
            } else if draft.contacts.isEmpty {
                // Two different answers, and the difference matters: one is a setting you can
                // change, the other is your server's policy and no amount of clicking here
                // will move it.
                ContentUnavailableView {
                    Label(
                        draft.browsesContacts ? "No Contacts to Show" : "Suggestions Are Off",
                        systemImage: draft.browsesContacts ? "person.2.slash" : "eye.slash"
                    )
                } description: {
                    Text(draft.browsesContacts
                         ? "This server may not list people until you search for them. Type a name in the To: field instead."
                         : "Turn on “Suggest people before you type” in Settings, or type a name in the To: field.")
                }
                .frame(width: 280)
                .padding(.vertical, 8)
            } else {
                List(draft.contacts) { entry in
                    ContactRow(entry: entry, isChosen: draft.isRecipient(entry)) {
                        draft.toggle(entry)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                }
                .listStyle(.inset)
                .frame(width: 300, height: 360)
            }
        }
        .task { if !draft.didBrowse { await draft.browseContacts() } }
    }
}

/// One person in the dropdown or the browser.
struct ContactRow: View {
    let entry: DirectoryEntry
    var isChosen = false
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: entry.source.symbolName)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.5), in: .circle)

                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.label)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let subline = entry.subline, !subline.isEmpty {
                        Text(subline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if isChosen {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
