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
        HStack(alignment: .center, spacing: 16) {
            ProfileAvatar(profile: profile, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .font(.title2.weight(.semibold))
                Text(profile.session.account.server.displayString)
                    .foregroundStyle(.secondary)
                if profile.statusSupport != nil, let status = profile.status {
                    HStack(spacing: 6) {
                        StatusDot(status: status.status, diameter: 9)
                        Text(status.status.title)
                        if let message = profile.statusMessage {
                            Text("·").foregroundStyle(.tertiary)
                            Text([message.icon, message.text].filter { !$0.isEmpty }.joined(separator: " "))
                                .lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
            }

            Spacer()

            Button("Edit in Nextcloud…") {
                NSWorkspace.shared.open(profile.links.personalInfo)
            }
        }
        .padding(.vertical, 6)
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
