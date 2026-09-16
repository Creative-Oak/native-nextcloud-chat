import AppKit
import SwiftUI

/// The app's own preferences, on this Mac — what the Settings window's General,
/// Notifications and Advanced tabs held — as cards on the Settings page.
struct PreferencesCards: View {
    @Bindable var preferences: Preferences

    var body: some View {
        InspectorCard(title: "Messages") {
            PreferenceToggle(
                title: "Return sends the message",
                caption: preferences.sendsOnReturn ? "Shift-Return inserts a line break." : "Return inserts a line break; ⌘Return sends.",
                isOn: $preferences.sendsOnReturn
            )
            PreferenceToggle(
                title: "Suggest people before you type",
                caption: "Asks your server for a list of people when you start a new message, which fills the contacts browser and lets kvidr match initials like “hvr” locally. Some servers do not list people until you search for them, in which case this finds nothing either way.",
                isOn: $preferences.browsesContacts
            )
        }

        InspectorCard(title: "Notifications") {
            PreferenceToggle(title: "Show notifications", isOn: $preferences.showsNotifications)
            PreferenceToggle(title: "Play a sound", isOn: $preferences.playsNotificationSound)
                .disabled(!preferences.showsNotifications)
            PreferenceToggle(title: "Show message previews", isOn: $preferences.showsNotificationPreviews)
                .disabled(!preferences.showsNotifications)
            PreferenceToggle(title: "Show unread count on the Dock icon", isOn: $preferences.showsDockBadge)
            Text("kvidr follows each conversation’s notification setting from Nextcloud — right-click a conversation in the sidebar to change it. Notifications arrive while kvidr is running; closing the window keeps it running, quitting does not.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            InspectorActionRow(title: "Open macOS Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        InspectorCard(title: "Advanced") {
            PreferenceToggle(
                title: "Verbose logging",
                caption: "Writes detailed logs, which may include message content, to the system log. Off by default.",
                isOn: $preferences.isDeveloperModeEnabled
            )
            PreferenceToggle(
                title: "Allow insecure local servers",
                caption: "Permits plain HTTP for localhost and private-network addresses only. Public servers always require HTTPS.",
                isOn: $preferences.allowsInsecureLocalServers
            )
        }
    }
}

/// A switch at the leading edge, its words after it, and a caption under the words when it
/// needs one.
private struct PreferenceToggle: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The words are part of the switch: clicking them flips it, as a checkbox's do.
            .contentShape(.rect)
            .onTapGesture { isOn.toggle() }
        }
    }
}
