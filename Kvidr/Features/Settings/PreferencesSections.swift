import AppKit
import SwiftUI

/// The app's own preferences, on this Mac — what the Settings window's General,
/// Notifications and Advanced tabs held, now sections of the Settings page.
struct PreferencesSections: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Section("General") {
            Picker("Return key", selection: $preferences.sendsOnReturn) {
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

        Section("New Messages") {
            Toggle("Suggest people before you type", isOn: $preferences.browsesContacts)
            Text("Asks your server for a list of people when you start a new message, which fills the contacts browser and lets kvidr match initials like “hvr” locally. Some servers do not list people until you search for them, in which case this finds nothing either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Notifications") {
            Toggle("Show notifications", isOn: $preferences.showsNotifications)
            Toggle("Play a sound", isOn: $preferences.playsNotificationSound)
                .disabled(!preferences.showsNotifications)
            Toggle("Show message previews", isOn: $preferences.showsNotificationPreviews)
                .disabled(!preferences.showsNotifications)
            Toggle("Show unread count on the Dock icon", isOn: $preferences.showsDockBadge)

            Text("kvidr follows each conversation’s notification setting from Nextcloud. Change it by right-clicking a conversation in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Notifications arrive while kvidr is running. Closing the window keeps it running; quitting it does not.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open macOS Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

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
