import AppKit
import SwiftUI

/// A link's preview under its message, the way Messages shows one: the page's image, then
/// a band with its title and host. Nothing at all until the page has answered — a card
/// that appears is better than a placeholder that reshapes itself.
struct LinkPreviewCard: View {
    let url: URL
    let isFromMe: Bool

    @Environment(\.linkPreviewLoader) private var loader
    @State private var preview: LinkPreview?

    /// Narrower than a text bubble may be: a preview is a glance, not a read.
    private static let width: CGFloat = 300
    private static let imageHeight: CGFloat = 170

    var body: some View {
        Group {
            if let preview {
                card(preview)
                    .transition(.opacity)
            }
        }
        .task(id: url) { await load() }
    }

    private func card(_ preview: LinkPreview) -> some View {
        Button {
            MessageLink.open(preview.url)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image = preview.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.width, height: Self.imageHeight)
                        .clipped()
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let title = preview.title {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                    }
                    Text(preview.host)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: Self.width, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: Self.width, alignment: .leading)
                // The same quiet fill as a received bubble, whichever side the card is
                // on: a page's title is the page's, not something you or they said.
                .background(Color.primary.opacity(0.09))
            }
            .foregroundStyle(.primary)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(preview.url.absoluteString)
        .contextMenu {
            Button("Open Link") { MessageLink.open(preview.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(preview.url.absoluteString, forType: .string)
            }
        }
        .accessibilityLabel("Link preview: \(preview.title ?? preview.host)")
    }

    private func load() async {
        // A card is fetched the moment the row appears, from this machine, at an address
        // the sender chose — see ``Foundation/URL/isPreviewableWebLink``. The loader
        // refuses the same addresses; asking here too keeps the log quiet about them.
        guard url.isPreviewableWebLink else { return }
        guard let loader else {
            Log.ui.warning("Link preview for \(url.host() ?? url.absoluteString): no loader in the environment")
            return
        }
        Log.ui.notice("Link preview requested for \(url.host() ?? url.absoluteString)")
        if let cached = loader.cached(url) {
            preview = cached
            return
        }
        guard !loader.hasNoPreview(url) else { return }
        let fetched = await loader.preview(for: url)
        withAnimation(.easeOut(duration: 0.2)) { preview = fetched }
    }
}
