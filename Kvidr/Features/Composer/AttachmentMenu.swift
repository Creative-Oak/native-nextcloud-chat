import AppKit
import PhotosUI
import SwiftUI

/// The composer's `+`: Photos, Files, and whatever else a conversation can be given.
///
/// Shared, because a draft has a composer too — and a draft's files go up before there is a
/// conversation to put them in, which the queue handles by taking its token late.
struct AttachmentMenu: View {
    @Bindable var queue: AttachmentQueue
    /// Named in the open panel's message, so it is clear where the files are going.
    var destination: String
    /// Extra items, for the things only a real conversation can do.
    @ViewBuilder var extraItems: () -> AnyView

    @State private var isShowingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []

    init(
        queue: AttachmentQueue,
        destination: String,
        @ViewBuilder extraItems: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.queue = queue
        self.destination = destination
        self.extraItems = extraItems
    }

    var body: some View {
        Menu {
            Button("Photos…", systemImage: "photo") { isShowingPhotos = true }
            Button("Files…", systemImage: "folder") { chooseFiles() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            extraItems()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: GlassMetrics.control, height: GlassMetrics.control)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        // The glass drawn by hand, as the other round controls draw theirs. `.buttonStyle(.glass)`
        // on a menu never painted the circle at all, so the plus sat there as a bare glyph
        // beside a fielded text box.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassCircle()
        .help("Add an attachment")
        .accessibilityLabel("Add an Attachment")
        // Apple's own picker, out of process: the user chooses inside it and only the chosen
        // items cross over, so a sandboxed app needs no library permission, no usage string
        // and no entitlement to send one photo.
        .photosPicker(
            isPresented: $isShowingPhotos,
            selection: $pickedPhotos,
            maxSelectionCount: nil,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: pickedPhotos) { _, picked in
            guard !picked.isEmpty else { return }
            pickedPhotos = []
            Task { await stage(picked) }
        }
    }

    /// Copies what Photos handed over into the queue. Originals, unconverted — HEIC included.
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
        queue.enqueue(urls: urls)
    }

    /// An open panel rather than a custom picker, because the system one already knows about
    /// tags, recents, iCloud and everything else.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Choose files to attach to \(destination)"

        guard panel.runModal() == .OK else { return }
        queue.enqueue(urls: panel.urls)
    }
}

/// A picked photo or video, copied to a file on the way out of Photos.
///
/// A `FileRepresentation` rather than `loadTransferable(type: Data.self)`: the `Data` route
/// holds a four-gigabyte video in memory before a byte of it is uploaded, and the upload
/// path wants a file anyway.
struct PickedPhoto: Transferable {
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
