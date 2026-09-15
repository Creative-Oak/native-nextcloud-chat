import Foundation
import Observation

/// The defaults keys, at file scope rather than nested in ``Preferences`` so they keep the
/// isolation they need: one of them is read from a `@Sendable` closure off the main actor,
/// and a member of a `@MainActor` type could not be.
private enum Key {
    static let showNotifications = "notifications.enabled"
    static let notificationSound = "notifications.sound"
    static let notificationPreviews = "notifications.previews"
    static let dockBadge = "notifications.dockBadge"
    static let sendOnReturn = "composer.sendOnReturn"
    static let browseContacts = "newMessage.browseContacts"
    static let allowInsecureLocalServers = "advanced.allowInsecureLocalServers"
    static let developerMode = "advanced.developerMode"
    static let lastSelectedToken = "state.lastSelectedToken"
    static let sidebarMode = "sidebar.mode"
}

/// User preferences.
///
/// `UserDefaults` only — no credentials, no message content, nothing that would be a
/// problem in a backup or a screen share.
///
/// The properties are **stored**, and write through to `UserDefaults` as they change.
/// That is not incidental: `@Observable` tracks stored properties and nothing else, so
/// while these were computed accessors over `defaults` the class announced no changes at
/// all. A view reading a preference registered no dependency on it, and changing one in
/// Settings left the rest of the app on the old value — the notification toggles below it
/// stayed enabled, the "Return sends" explanation contradicted the picker above it, and
/// the composer went on treating Return the way it had a moment ago.
@MainActor
@Observable
final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    var showsNotifications: Bool {
        didSet { defaults.set(showsNotifications, forKey: Key.showNotifications) }
    }

    var playsNotificationSound: Bool {
        didSet { defaults.set(playsNotificationSound, forKey: Key.notificationSound) }
    }

    /// When off, notifications say who and where but not what — for shared screens.
    var showsNotificationPreviews: Bool {
        didSet { defaults.set(showsNotificationPreviews, forKey: Key.notificationPreviews) }
    }

    var showsDockBadge: Bool {
        didSet { defaults.set(showsDockBadge, forKey: Key.dockBadge) }
    }

    /// Return sends, Shift-Return inserts a newline. Inverted when this is off.
    var sendsOnReturn: Bool {
        didSet { defaults.set(sendsOnReturn, forKey: Key.sendOnReturn) }
    }

    /// Developer escape hatch for plain-HTTP servers on localhost and private networks.
    /// Never allows insecure connections to a public host.
    /// Whether a new message asks the server for a list of people before you have typed
    /// anything — which fills the contact browser behind the `+`, and the list the fuzzy
    /// matching searches locally.
    ///
    /// On by default, and off is a real choice rather than a fallback: the request asks the
    /// server for a page of everyone you may see, which is more than "find me Heine" and not
    /// everyone wants their client doing it unprompted.
    var browsesContacts: Bool {
        didSet { defaults.set(browsesContacts, forKey: Key.browseContacts) }
    }

    var allowsInsecureLocalServers: Bool {
        didSet { defaults.set(allowsInsecureLocalServers, forKey: Key.allowInsecureLocalServers) }
    }

    var isDeveloperModeEnabled: Bool {
        didSet {
            defaults.set(isDeveloperModeEnabled, forKey: Key.developerMode)
            Log.isDeveloperModeEnabled = isDeveloperModeEnabled
        }
    }

    /// Restores the sidebar selection across launches.
    var lastSelectedToken: String? {
        didSet { defaults.set(lastSelectedToken, forKey: Key.lastSelectedToken) }
    }

    /// Which of its two widths the sidebar is at. Remembered like the window frame is:
    /// the sidebar you folded down stays folded down next time.
    var sidebarMode: SidebarMode {
        didSet { defaults.set(sidebarMode.rawValue, forKey: Key.sidebarMode) }
    }

    /// Read directly from `UserDefaults` by code that can't reach the main actor.
    nonisolated static let allowInsecureLocalServersKey = Key.allowInsecureLocalServers

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showNotifications: true,
            Key.notificationSound: true,
            Key.notificationPreviews: true,
            Key.dockBadge: true,
            Key.sendOnReturn: true,
            Key.browseContacts: true,
            Key.allowInsecureLocalServers: false,
            Key.developerMode: false
        ])

        showsNotifications = defaults.bool(forKey: Key.showNotifications)
        playsNotificationSound = defaults.bool(forKey: Key.notificationSound)
        showsNotificationPreviews = defaults.bool(forKey: Key.notificationPreviews)
        showsDockBadge = defaults.bool(forKey: Key.dockBadge)
        sendsOnReturn = defaults.bool(forKey: Key.sendOnReturn)
        browsesContacts = defaults.bool(forKey: Key.browseContacts)
        allowsInsecureLocalServers = defaults.bool(forKey: Key.allowInsecureLocalServers)
        isDeveloperModeEnabled = defaults.bool(forKey: Key.developerMode)
        lastSelectedToken = defaults.string(forKey: Key.lastSelectedToken)
        sidebarMode = defaults.string(forKey: Key.sidebarMode).flatMap(SidebarMode.init(rawValue:)) ?? .standard
    }
}
