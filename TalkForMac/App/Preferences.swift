import Foundation
import Observation

/// User preferences.
///
/// `UserDefaults` only — no credentials, no message content, nothing that would be a
/// problem in a backup or a screen share.
@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showNotifications: true,
            Key.notificationSound: true,
            Key.notificationPreviews: true,
            Key.dockBadge: true,
            Key.sendOnReturn: true,
            Key.allowInsecureLocalServers: false,
            Key.developerMode: false
        ])
    }

    private enum Key {
        static let showNotifications = "notifications.enabled"
        static let notificationSound = "notifications.sound"
        static let notificationPreviews = "notifications.previews"
        static let dockBadge = "notifications.dockBadge"
        static let sendOnReturn = "composer.sendOnReturn"
        static let allowInsecureLocalServers = "advanced.allowInsecureLocalServers"
        static let developerMode = "advanced.developerMode"
        static let lastSelectedToken = "state.lastSelectedToken"
    }

    var showsNotifications: Bool {
        get { defaults.bool(forKey: Key.showNotifications) }
        set { defaults.set(newValue, forKey: Key.showNotifications) }
    }

    var playsNotificationSound: Bool {
        get { defaults.bool(forKey: Key.notificationSound) }
        set { defaults.set(newValue, forKey: Key.notificationSound) }
    }

    /// When off, notifications say who and where but not what — for shared screens.
    var showsNotificationPreviews: Bool {
        get { defaults.bool(forKey: Key.notificationPreviews) }
        set { defaults.set(newValue, forKey: Key.notificationPreviews) }
    }

    var showsDockBadge: Bool {
        get { defaults.bool(forKey: Key.dockBadge) }
        set { defaults.set(newValue, forKey: Key.dockBadge) }
    }

    /// Return sends, Shift-Return inserts a newline. Inverted when this is off.
    var sendsOnReturn: Bool {
        get { defaults.bool(forKey: Key.sendOnReturn) }
        set { defaults.set(newValue, forKey: Key.sendOnReturn) }
    }

    /// Developer escape hatch for plain-HTTP servers on localhost and private networks.
    /// Never allows insecure connections to a public host.
    var allowsInsecureLocalServers: Bool {
        get { defaults.bool(forKey: Key.allowInsecureLocalServers) }
        set { defaults.set(newValue, forKey: Key.allowInsecureLocalServers) }
    }

    var isDeveloperModeEnabled: Bool {
        get { defaults.bool(forKey: Key.developerMode) }
        set {
            defaults.set(newValue, forKey: Key.developerMode)
            Log.isDeveloperModeEnabled = newValue
        }
    }

    /// Restores the sidebar selection across launches.
    var lastSelectedToken: String? {
        get { defaults.string(forKey: Key.lastSelectedToken) }
        set { defaults.set(newValue, forKey: Key.lastSelectedToken) }
    }
}
