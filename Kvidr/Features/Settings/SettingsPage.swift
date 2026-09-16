import AppKit
import SwiftUI

/// Settings, in the messages column: who you are on Nextcloud, this Mac's sign-in, and the
/// app's own preferences — one scrolling page.
struct SettingsPage: View {
    let profile: ProfileModel
    @Environment(AppModel.self) private var app
    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                SettingsHeader(profile: profile)
            }

            ProfileSection(profile: profile)

            thisMac

            PreferencesSections(preferences: app.dependencies.preferences)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await profile.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The way back from "Edit in Nextcloud…": whatever changed in the browser shows
            // up the moment kvidr is in front again.
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

    private var thisMac: some View {
        let account = profile.session.account
        return Section("This Mac") {
            LabeledContent("Server", value: account.server.displayString)
            LabeledContent("Account", value: account.userID)
            LabeledContent("Status") {
                Label(app.connection == .offline ? "Offline" : "Connected",
                      systemImage: app.connection == .offline ? "wifi.slash" : "checkmark.circle.fill")
                    .foregroundStyle(app.connection == .offline ? Color.secondary : Color.green)
            }
            LabeledContent("Nextcloud", value: account.capabilities.serverVersion.string)
            LabeledContent("Talk", value: account.capabilities.talkVersion ?? "unknown")

            Button("Manage Devices in Nextcloud…") {
                NSWorkspace.shared.open(profile.links.security)
            }
            Text("Nextcloud doesn’t let an app list or sign out your other devices. Security in Nextcloud does both.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Remove Account…", role: .destructive) { isConfirmingRemoval = true }
        }
    }
}

/// Picture, name, server and status, at the top of the page.
private struct SettingsHeader: View {
    let profile: ProfileModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                PictureControl(profile: profile)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.title2.weight(.semibold))
                    Text(profile.session.account.server.displayString)
                        .foregroundStyle(.secondary)
                    SaveIndicator(save: profile.pictureSave, savedText: "Picture updated")
                }

                Spacer()

                Button("Edit in Nextcloud…") {
                    NSWorkspace.shared.open(profile.links.personalInfo)
                }
                .help("Change your name and profile on Nextcloud’s Personal info page")
            }

            if let support = profile.statusSupport {
                StatusEditor(profile: profile, support: support)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The picture, which is also the button that changes it.
private struct PictureControl: View {
    let profile: ProfileModel
    @Environment(\.avatarLoader) private var avatarLoader
    @State private var pending: PendingPicture?
    @State private var isPreparing = false

    var body: some View {
        Menu {
            Button("Choose Picture…") { choose() }
            Button("Remove Picture", role: .destructive) {
                Task { await profile.removePicture(avatarLoader: avatarLoader) }
            }
        } label: {
            ProfileAvatar(profile: profile, size: 64, showsStatus: false)
                .overlay {
                    if isPreparing || profile.pictureSave == .saving {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change your picture")
        .sheet(item: $pending) { picture in
            PictureConfirmation(profile: profile, picture: picture) { pending = nil }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for your Nextcloud profile"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        profile.resetPictureSave()
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do throws(TalkError) {
                pending = PendingPicture(png: try await ProfileModel.preparePicture(from: url))
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

    var body: some View {
        VStack(spacing: 16) {
            Text("New Picture")
                .font(.headline)

            if let png = picture.png, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 160)
                    .clipShape(.circle)
                    .overlay { Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
                Text("Everyone who can see you in Nextcloud sees this picture.")
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
                Button("Cancel", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                if let png = picture.png {
                    Button("Use Picture") {
                        Task {
                            if await profile.setPicture(png: png, avatarLoader: avatarLoader) { onClose() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.pictureSave == .saving)
                }
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private var failure: String? {
        if case .failed(let reason) = profile.pictureSave { return reason }
        return nil
    }
}

/// Presence and the status message, saved as they change.
private struct StatusEditor: View {
    let profile: ProfileModel
    let support: UserStatusSupport

    @State private var icon = ""
    @State private var text = ""
    @State private var clearAfter: ClearAfter = .never
    @FocusState private var focused: Field?

    private enum Field { case icon, text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(OnlineStatus.choosable(supportsBusy: support.supportsBusy), id: \.self) { choice in
                        Button {
                            Task { await profile.setStatus(choice) }
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
                .fixedSize()

                if !profile.predefinedStatuses.isEmpty {
                    Menu("Suggestions") {
                        ForEach(profile.predefinedStatuses) { predefined in
                            Button("\(predefined.icon) \(predefined.message)") {
                                Task { await profile.applyPredefined(predefined) }
                            }
                        }
                    }
                    .fixedSize()
                }

                Spacer()
                SaveIndicator(save: profile.statusSave, savedText: "Saved")
            }

            HStack(spacing: 8) {
                if support.supportsEmoji {
                    TextField("🙂", text: $icon)
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .focused($focused, equals: .icon)
                        .onSubmit { commit() }
                        .onChange(of: icon) { _, new in
                            // One emoji: whatever was typed last.
                            if new.count > 1, let last = new.last { icon = String(last) }
                        }
                }
                TextField("What’s your status?", text: $text)
                    .focused($focused, equals: .text)
                    .onSubmit { commit() }
                Picker("Clear after", selection: $clearAfter) {
                    ForEach(ClearAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: clearAfter) { _, _ in
                    // A new clear-after is a change even when the words are the same.
                    if !text.isEmpty || !icon.isEmpty { commit(force: true) }
                }
                if profile.status?.hasMessage == true {
                    Button("Clear") {
                        icon = ""
                        text = ""
                        clearAfter = .never
                        Task { await profile.clearMessage() }
                    }
                }
            }

            if let clearAt = profile.status?.clearAt, profile.status?.hasMessage == true {
                Text("Clears \(clearAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: syncFromServer)
        .onChange(of: profile.status) { _, _ in syncFromServer() }
        .onChange(of: focused) { old, new in
            // Leaving the fields is a commit, as Return is.
            if old != nil && new == nil { commit() }
        }
    }

    private var currentStatus: OnlineStatus {
        profile.status?.status ?? .online
    }

    /// The fields follow the server unless they are being typed in.
    private func syncFromServer() {
        guard focused == nil else { return }
        let message = profile.statusMessage
        icon = message?.icon ?? ""
        text = message?.text ?? ""
    }

    /// Sends the message if it differs from what the server has — leaving a field you only
    /// clicked into sends nothing.
    private func commit(force: Bool = false) {
        let shown = profile.statusMessage
        guard force || icon != (shown?.icon ?? "") || text != (shown?.text ?? "") else { return }
        let icon = icon, text = text, clearAfter = clearAfter
        Task { await profile.setMessage(icon: icon, text: text, clearAfter: clearAfter) }
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
                .font(.caption)
                .foregroundStyle(.green)
                .transition(.opacity)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

/// The Personal info page's fields, as they are on the server. Read-only here: editing them
/// needs a confirmed password, which an app password never has.
private struct ProfileSection: View {
    let profile: ProfileModel

    var body: some View {
        Section {
            switch profile.profileLoad {
            case .idle, .loading where profile.profile == nil:
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn’t load your profile")
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await profile.load() } }
                }
            default:
                if let loaded = profile.profile {
                    if loaded.fields.isEmpty {
                        Text("Nothing on your profile yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(loaded.fields) { field in
                        ProfileFieldRow(field: field)
                    }
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            HStack {
                Button("Edit in Nextcloud…") { NSWorkspace.shared.open(profile.links.personalInfo) }
                if profile.profile?.isProfileEnabled == true {
                    Button("View Profile…") { NSWorkspace.shared.open(profile.links.publicProfile) }
                }
                Spacer()
            }
            .buttonStyle(.link)
            .padding(.top, 4)
        }
    }
}

private struct ProfileFieldRow: View {
    let field: ProfileField

    var body: some View {
        LabeledContent {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                value
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                if let scope = field.scope {
                    Text(scope.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .help(scope.explanation)
                        .fixedSize()
                }
            }
        } label: {
            Text(field.kind.title)
        }
    }

    @ViewBuilder
    private var value: some View {
        // A website only becomes a link through the same check message links go through.
        if field.kind == .website, let url = URL(string: field.value), url.isOpenableLink {
            Link(field.value, destination: url)
        } else {
            Text(field.value)
                .lineLimit(field.kind.isMultiline ? nil : 1)
        }
    }
}
