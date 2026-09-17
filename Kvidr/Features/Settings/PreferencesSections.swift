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

        InspectorCard(title: "Voice Messages") {
            PreferenceToggle(
                title: "Transcribe voice messages",
                caption: "Writes out what was said under each voice message. It happens on this Mac — the recording isn’t sent anywhere. The first time, macOS may download the language’s speech model.",
                isOn: $preferences.transcribesVoiceMessages
            )
            TranscriptionLanguagePicker(preferences: preferences)
                .disabled(!preferences.transcribesVoiceMessages)
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

/// Its words on the left with a caption under them when it needs one, and the switch at the
/// trailing edge, where macOS puts it.
private struct PreferenceToggle: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// Which language voice messages are transcribed in. Only languages this Mac has a speech
/// model for are offered; "Automatic" follows the Mac's own language.
private struct TranscriptionLanguagePicker: View {
    @Bindable var preferences: Preferences
    @Environment(AppModel.self) private var app
    @State private var languages: [Locale] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Language")
                    .font(.system(size: 13))
                Text("Transcripts are in one language. Choose the one most voice messages are spoken in.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("Language", selection: $preferences.transcriptionLanguage) {
                Text("Automatic").tag(String?.none)
                Divider()
                ForEach(languages, id: \.identifier) { locale in
                    Text(VoiceTranscriber.name(of: locale)).tag(Optional(locale.identifier))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .task { languages = await VoiceTranscriber.supportedLanguages() }
        .onChange(of: preferences.transcriptionLanguage) {
            app.voicePlayer?.transcriber.reset()
        }
        // Turning it back on writes out what is already on screen, too.
        .onChange(of: preferences.transcribesVoiceMessages) { _, isOn in
            if isOn { app.voicePlayer?.transcriber.reset() }
        }
    }
}

