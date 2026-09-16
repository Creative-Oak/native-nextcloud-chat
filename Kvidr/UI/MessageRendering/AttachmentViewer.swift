import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                    Text(object.displayName)
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
                        MessageLink.open(link)
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
        // The prefill is a server-chosen name, and the panel is the last place the user
        // reads it before it becomes a file: a name that reverses itself in the field is
        // not the name that ends up on disk.
        panel.nameFieldStringValue = Self.suggestedName(for: object.displayName)
        // What this writes is a re-encoded bitmap, and these are the only two things it
        // knows how to write. Saying so keeps the panel from offering a name whose extension
        // promises something else — the whole `.jpeg` that turns out to hold PNG bytes.
        panel.allowedContentTypes = [.png, .jpeg]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The bytes decide the extension, not the other way round. This used to ask only
        // whether the extension was exactly `jpg`, so `.jpeg` — which the panel itself is
        // happy to produce — got a PNG inside it, and so did `.gif`, `.pdf` and anything
        // else the server's name suggested. A file whose name and contents disagree is the
        // problem, however harmless the mismatch looks here.
        let isJPEG = Self.jpegExtensions.contains(url.pathExtension.lowercased())
        let destination = isJPEG || url.pathExtension.lowercased() == "png"
            ? url
            : url.appendingPathExtension("png")

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: isJPEG ? .jpeg : .png, properties: [:])
        else { return }
        try? data.write(to: destination)
    }

    /// What to put in the panel's name field, given a name the server chose.
    ///
    /// Three things are wrong with using it as it stands. It can carry a path separator, and
    /// `/` in a name field is not a name — on the way to disk it is a directory boundary, and
    /// `:` is the same character seen from the Finder's side. It can begin with a dot, which
    /// is how a file stops being visible. And it can claim an extension that has nothing to
    /// do with what is about to be written, so the saved copy of a picture is called
    /// `invoice.pdf` and opens as one somewhere else later.
    ///
    /// Invisible marks are already gone by here — ``RichObject/displayName`` strips them —
    /// which is what stops the name reversing itself in the field.
    private static func suggestedName(for displayName: String) -> String {
        var name = displayName
        for separator in ["/", ":", "\\"] {
            name = name.replacingOccurrences(of: separator, with: "-")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        guard !name.isEmpty else { return "Image.png" }

        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        guard ext == "png" || jpegExtensions.contains(ext) else { return "\(name).png" }
        return name
    }

    /// Both spellings. Only `jpg` was recognised, and `jpeg` is the one the save panel
    /// produces when it is told the type rather than the extension.
    private static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
}
