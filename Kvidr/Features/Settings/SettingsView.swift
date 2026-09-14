import AppKit
import SwiftUI

/// A real Settings scene, in the shape macOS expects.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell") { NotificationSettings() }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .frame(width: 480)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(\.preferences) private var preferences

    var body: some View {
        Form {
            if let preferences {
                @Bindable var preferences = preferences
                Picker("Return key:", selection: $preferences.sendsOnReturn) {
                    Text("Sends the message").tag(true)
                    Text("Inserts a line break").tag(false)
                }
                .pickerStyle(.radioGroup)

                Text(preferences.sendsOnReturn
                     ? "Shift-Return inserts a line break."
                     : "⌘Return sends the message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @Environment(\.preferences) private var preferences

    var body: some View {
        Form {
            if let preferences {
                @Bindable var preferences = preferences

                Toggle("Show notifications", isOn: $preferences.showsNotifications)
                Toggle("Play a sound", isOn: $preferences.playsNotificationSound)
                    .disabled(!preferences.showsNotifications)
                Toggle("Show message previews", isOn: $preferences.showsNotificationPreviews)
                    .disabled(!preferences.showsNotifications)
                Toggle("Show unread count on the Dock icon", isOn: $preferences.showsDockBadge)

                Section {
                    Text("kvidr follows each conversation’s notification setting from Nextcloud. Change it by right-clicking a conversation in the sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Notifications arrive while kvidr is running. Closing the window keeps it running; quitting it does not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Open macOS Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var isConfirmingSignOut = false

    var body: some View {
        Form {
            if let session = app.session {
                let account = session.account
                LabeledContent("Server", value: account.server.displayString)
                LabeledContent("Signed in as", value: account.resolvedDisplayName)
                LabeledContent("Account", value: account.userID)
                LabeledContent("Status") {
                    switch app.phase {
                    case .needsReauthentication:
                        Label("Needs sign-in", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    default:
                        Label(app.connection == .offline ? "Offline" : "Connected",
                              systemImage: app.connection == .offline ? "wifi.slash" : "checkmark.circle.fill")
                            // Both branches have to be the same shape style; `.secondary`
                            // and `.green` are different types.
                            .foregroundStyle(app.connection == .offline ? Color.secondary : Color.green)
                    }
                }

                Section("Server") {
                    LabeledContent("Nextcloud", value: account.capabilities.serverVersion.string)
                    LabeledContent("Talk", value: account.capabilities.talkVersion ?? "unknown")
                }

                Section {
                    Button("Remove Account…", role: .destructive) { isConfirmingSignOut = true }
                    Text("Removes the account from this Mac and revokes this app’s access in Nextcloud. Your messages stay on the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No Account", systemImage: "person.crop.circle.badge.plus")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove this account?", isPresented: $isConfirmingSignOut) {
            Button("Remove Account", role: .destructive) {
                Task { await app.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached conversations and drafts on this Mac will be deleted.")
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(\.preferences) private var preferences

    var body: some View {
        Form {
            if let preferences {
                @Bindable var preferences = preferences

                Section("Diagnostics") {
                    Toggle("Verbose logging", isOn: $preferences.isDeveloperModeEnabled)
                    Text("Writes detailed logs, which may include message content, to the system log. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reveal Logs in Console…") {
                        if let url = URL(string: "x-apple.systempreferences:") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Section("Development") {
                    Toggle("Allow insecure local servers", isOn: $preferences.allowsInsecureLocalServers)
                    Text("Permits plain HTTP for localhost and private-network addresses only. Public servers always require HTTPS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
