import AppKit
import SwiftUI

/// The in-app image viewer.
///
/// A Quick Look-ish overlay rather than a new window: it appears over the conversation,
/// Escape or a click outside dismisses it, and the chrome is glass so the picture is the
/// only thing that reads as content.
struct AttachmentViewer: View {
    let object: RichObject
    var onDismiss: () -> Void

    @Environment(\.previewLoader) private var loader
    @State private var image: NSImage?
    @State private var isSaving = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 12) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 240, height: 180)
                }

                chrome
            }
            .padding(40)
        }
        .task(id: object.id) {
            if let cached = loader?.cached(fileID: object.id, width: 1600) {
                image = cached
            } else {
                image = await loader?.fullSize(fileID: object.id)
            }
        }
        .onExitCommand(perform: onDismiss)
        .transition(.opacity)
    }

    private var chrome: some View {
        GlassEffectContainer(spacing: GlassSpacing.distinct) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(object.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size = object.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)

                Divider().frame(height: 20)

                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(image == nil || isSaving)
                .help("Save a copy…")

                if let link = object.link {
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        Label("Open in Nextcloud", systemImage: "arrow.up.forward.app")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Nextcloud")
                }

                Button(action: onDismiss) {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Close (Escape)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glass(.floating, cornerRadius: 14)
        }
    }

    /// A save panel, so the copy lands wherever the user actually wants it — which a
    /// sandboxed app can't decide for them anyway.
    private func save() {
        guard let image else { return }
        isSaving = true
        defer { isSaving = false }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = object.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: url.pathExtension.lowercased() == "jpg" ? .jpeg : .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }
}
