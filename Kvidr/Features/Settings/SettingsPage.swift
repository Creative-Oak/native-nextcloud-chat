import AppKit
import PhotosUI
import SwiftUI

/// Settings, in the messages column: who you are on Nextcloud, this Mac's sign-in, and the
/// app's own preferences.
///
/// Drawn the way the inspector is — the face large and centred, round buttons under it,
/// then rounded cards with a small grey label over each value — so the two panels that
/// describe a person read as one family. It uses the inspector's own cards rather than
/// imitations of them.
struct SettingsPage: View {
    let profile: ProfileModel
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var isConfirmingRemoval = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                identity
                actions

                VStack(spacing: 14) {
                    if let support = profile.statusSupport {
                        StatusCard(profile: profile, support: support)
                    }
                    ProfileCard(profile: profile)
                    thisMac
                    PreferencesCards(preferences: app.dependencies.preferences)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
        }
        .background {
            // The inspector's page: recessed so the cards read as cards, with a wash of the
            // accent behind the face.
            ZStack {
                Color(nsColor: .textBackgroundColor)
                if colorScheme == .light { Color.primary.opacity(0.045) }
                LinearGradient(
                    colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.3)
                )
            }
            .ignoresSafeArea()
        }
        .task { await profile.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The way back from "Edit in Nextcloud": whatever changed in the browser shows up
            // the moment kvidr is in front again.
            Task { await profile.load() }
        }
        .confirmationDialog("Remove this account?", isPresented: $isConfirmingRemoval) {
            Button("Remove Account", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("kvidr’s access in Nextcloud is revoked, and the conversations and drafts kept on this Mac are deleted. Your messages stay on the server.")
        }
    }

    private var identity: some View {
        VStack(spacing: 8) {
            PictureControl(profile: profile)
                .padding(.bottom, 2)
            Text(profile.displayName)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text(profile.session.account.server.displayString)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            SaveIndicator(save: profile.pictureSave, savedText: "Picture updated")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var actions: some View {
        HStack(spacing: 16) {
            InspectorAction(symbol: "safari", label: "Edit Profile in Nextcloud") {
                NSWorkspace.shared.open(profile.links.personalInfo)
            }
            if profile.profile?.isProfileEnabled == true {
                InspectorAction(symbol: "person.crop.circle", label: "View Public Profile") {
                    NSWorkspace.shared.open(profile.links.publicProfile)
                }
            }
            InspectorAction(symbol: "lock.shield", label: "Security and Devices in Nextcloud") {
                NSWorkspace.shared.open(profile.links.security)
            }
        }
    }

    private var thisMac: some View {
        let account = profile.session.account
        return InspectorCard(title: "This Mac") {
            InspectorRow(label: "Server", value: account.server.displayString)
            InspectorRow(label: "Account", value: account.userID)
            InspectorRow(label: "Connection", value: app.connection == .offline ? "Offline" : "Connected")
            InspectorRow(
                label: "Versions",
                value: "Nextcloud \(account.capabilities.serverVersion.string) · Talk \(account.capabilities.talkVersion ?? "unknown")"
            )
            InspectorActionRow(title: "Manage Devices in Nextcloud…") {
                NSWorkspace.shared.open(profile.links.security)
            }
            InspectorActionRow(title: "Remove Account…", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
    }
}

// MARK: - Picture

/// The picture, which is also the menu that changes it.
private struct PictureControl: View {
    let profile: ProfileModel
    @Environment(\.avatarLoader) private var avatarLoader
    @State private var pending: PendingPicture?
    @State private var isPreparing = false
    @State private var isShowingPhotos = false
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        Menu {
            Button("Photos…", systemImage: "photo") { isShowingPhotos = true }
            Button("Choose File…", systemImage: "folder") { chooseFile() }
            Divider()
            Button("Remove Picture", systemImage: "trash", role: .destructive) {
                Task { await profile.removePicture(avatarLoader: avatarLoader) }
            }
        } label: {
            ProfileAvatar(profile: profile, size: 72, showsStatus: false)
                .overlay {
                    if isPreparing || profile.pictureSave == .saving {
                        Circle().fill(.black.opacity(0.4))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .glassEffect(.regular, in: .circle)
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .pointerStyle(.link)
        .fixedSize()
        .help("Change your picture")
        .photosPicker(isPresented: $isShowingPhotos, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            pickedPhoto = nil
            prepare { () async throws(TalkError) -> Data in
                guard let picked = try? await item.loadTransferable(type: PickedPhoto.self) else {
                    throw TalkError.fileNotAPicture
                }
                defer {
                    // The picker's copy was made for this, and has served its purpose.
                    let directory = picked.url.deletingLastPathComponent()
                    if directory.isContained(in: AttachmentScratch.directory) {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
                return try await ProfileModel.preparePicture(from: picked.url)
            }
        }
        .sheet(item: $pending) { picture in
            PictureConfirmation(profile: profile, picture: picture) { pending = nil }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose a picture for your Nextcloud profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepare { () async throws(TalkError) -> Data in try await ProfileModel.preparePicture(from: url) }
    }

    private func prepare(_ work: @escaping () async throws(TalkError) -> Data) {
        profile.resetPictureSave()
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do throws(TalkError) {
                pending = PendingPicture(png: try await work())
            } catch {
                pending = PendingPicture(png: nil, error: error.userMessage)
            }
        }
    }
}

private struct PendingPicture: Identifiable {
    let id = UUID()
    var png: Data?
    var error: String?
}

/// The squared picture, shown before it replaces the one on the server.
private struct PictureConfirmation: View {
    let profile: ProfileModel
    let picture: PendingPicture
    let onClose: () -> Void
    @Environment(\.avatarLoader) private var avatarLoader

    private var isUploading: Bool { profile.pictureSave == .saving }

    var body: some View {
        VStack(spacing: 16) {
            Text(picture.png == nil ? "Couldn’t Use That Picture" : "New Picture")
                .font(.headline)

            if let png = picture.png, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 160)
                    .clipShape(.circle)
                    .overlay { Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                    .overlay {
                        if isUploading {
                            Circle().fill(.black.opacity(0.4))
                            ProgressView().tint(.white)
                        }
                    }
                Text(isUploading ? "Uploading to Nextcloud…" : "Everyone who can see you in Nextcloud sees this picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = picture.error ?? failure {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button(picture.png == nil ? "OK" : "Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUploading)
                if let png = picture.png {
                    Button(isUploading ? "Uploading…" : "Use Picture") {
                        Task {
                            if await profile.setPicture(png: png, avatarLoader: avatarLoader) { onClose() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUploading)
                }
            }
        }
        .padding(24)
        .frame(width: 320)
        .interactiveDismissDisabled(isUploading)
    }

    private var failure: String? {
        if case .failed(let reason) = profile.pictureSave { return reason }
        return nil
    }
}

// MARK: - Status

/// Presence, the message, when it clears, and the server's suggestions — saved as they change.
private struct StatusCard: View {
    let profile: ProfileModel
    let support: UserStatusSupport

    @State private var icon = ""
    @State private var text = ""
    @State private var clearAfter: ClearAfter = .never
    @FocusState private var isTextFocused: Bool

    var body: some View {
        InspectorCard(title: "Status") {
            HStack {
                Text("Availability")
                    .font(.system(size: 13))
                Spacer()
                SaveIndicator(save: profile.statusSave, savedText: "Saved")
                Menu {
                    ForEach(OnlineStatus.choosable(supportsBusy: support.supportsBusy), id: \.self) { choice in
                        Button {
                            profile.setStatus(choice)
                        } label: {
                            if choice == currentStatus {
                                Label(choice.title, systemImage: "checkmark")
                            } else {
                                Text(choice.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        StatusDot(status: currentStatus, diameter: 9)
                        Text(currentStatus.title)
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }

            HStack(spacing: 8) {
                if support.supportsEmoji {
                    EmojiPickerButton(emoji: icon) { picked in
                        icon = picked
                        commit(force: true)
                    }
                }
                TextField("What’s your status?", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 8, style: .continuous))
                    .focused($isTextFocused)
                    .onSubmit { commit() }
                if profile.status?.hasMessage == true {
                    Button {
                        icon = ""
                        text = ""
                        clearAfter = .never
                        profile.clearMessage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .help("Clear status message")
                }
            }

            HStack {
                Text("Clear after")
                    .font(.system(size: 13))
                Spacer()
                Picker("Clear after", selection: Binding(
                    get: { clearAfter },
                    set: { new in
                        clearAfter = new
                        // A new time is a change even when the words are the same.
                        if !text.isEmpty || !icon.isEmpty { commit(force: true) }
                    }
                )) {
                    ForEach(ClearAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let clearAt = profile.status?.clearAt, profile.status?.hasMessage == true {
                Text("Clears \(clearAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            ForEach(profile.predefinedStatuses) { predefined in
                Button {
                    // The fields first, then the model, which changes before it returns — so
                    // the text field losing focus to this click finds nothing left to save.
                    icon = predefined.icon
                    text = predefined.message
                    clearAfter = predefined.clearAfter
                    isTextFocused = false
                    profile.applyPredefined(predefined)
                } label: {
                    HStack(spacing: 8) {
                        Text(predefined.icon).frame(width: 20)
                        Text(predefined.message)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(predefined.clearAfter.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 13))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .onAppear(perform: syncFromServer)
        .onChange(of: profile.status) { _, _ in syncFromServer() }
        .onChange(of: isTextFocused) { wasFocused, focused in
            // Leaving the field is a commit, as Return is.
            if wasFocused && !focused { commit() }
        }
    }

    private var currentStatus: OnlineStatus {
        profile.status?.status ?? .online
    }

    /// The fields follow the server, except while they are being typed in.
    private func syncFromServer() {
        guard !isTextFocused else { return }
        let message = profile.statusMessage
        icon = message?.icon ?? ""
        text = message?.text ?? ""
        if profile.status?.clearAt == nil { clearAfter = .never }
    }

    /// Sends the message if it differs from what the server has — clicking into the field and
    /// out again sends nothing.
    private func commit(force: Bool = false) {
        let shown = profile.statusMessage
        guard force || icon != (shown?.icon ?? "") || text != (shown?.text ?? "") else { return }
        profile.setMessage(icon: icon, text: text, clearAfter: clearAfter)
    }
}

/// The status emoji: a button that opens the system's emoji palette and keeps what is chosen.
///
/// The palette types into whatever has focus, so a field too small to see takes focus first
/// and hands on the first emoji it receives.
private struct EmojiPickerButton: View {
    let emoji: String
    let onPick: (String) -> Void

    @State private var catcher = ""
    @FocusState private var isCatching: Bool

    var body: some View {
        ZStack {
            TextField("", text: $catcher)
                .textFieldStyle(.plain)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .focused($isCatching)
                .onChange(of: catcher) { _, new in
                    guard let last = new.last else { return }
                    catcher = ""
                    isCatching = false
                    onPick(String(last))
                }
                .accessibilityHidden(true)

            Button {
                isCatching = true
                Task { @MainActor in NSApplication.shared.orderFrontCharacterPalette(nil) }
            } label: {
                Group {
                    if emoji.isEmpty {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(emoji).font(.system(size: 18))
                    }
                }
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.7), in: .circle)
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Choose an emoji")
            .accessibilityLabel(emoji.isEmpty ? "Choose an emoji" : "Emoji \(emoji)")
        }
    }
}

/// A spinner while saving, a checkmark once saved, the reason if it wasn't.
private struct SaveIndicator: View {
    let save: ProfileModel.Save
    let savedText: String

    var body: some View {
        switch save {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView().controlSize(.mini)
        case .saved:
            Label(savedText, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .transition(.opacity)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

// MARK: - Profile

/// The Personal info page's fields, as they are on the server. Read-only here: editing them
/// needs a confirmed password, which an app password never has.
private struct ProfileCard: View {
    let profile: ProfileModel

    var body: some View {
        InspectorCard(title: "Profile") {
            switch profile.profileLoad {
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t load your profile")
                        .font(.system(size: 13))
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                InspectorActionRow(title: "Try Again") { Task { await profile.load() } }
            default:
                if let loaded = profile.profile {
                    if loaded.fields.isEmpty {
                        Text("Nothing on your profile yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(loaded.fields) { field in
                        ProfileFieldRow(field: field)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            InspectorActionRow(title: "Edit in Nextcloud…") {
                NSWorkspace.shared.open(profile.links.personalInfo)
            }
        }
    }
}

/// A label over its value, as the inspector's rows are, with who can see it at the side.
private struct ProfileFieldRow: View {
    let field: ProfileField

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.kind.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                value
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let scope = field.scope {
                Text(scope.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .help(scope.explanation)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        // A website only becomes a link through the same check message links go through.
        if field.kind == .website, let url = URL(string: field.value), url.isOpenableLink {
            Link(field.value, destination: url)
                .pointerStyle(.link)
        } else {
            Text(field.value)
        }
    }
}
