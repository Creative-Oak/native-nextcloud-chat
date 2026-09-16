import Foundation
import Observation

/// The signed-in user as Nextcloud has them: profile, status, and whether the server lets
/// status be set at all.
///
/// One per session, read by the sidebar's account row and the Settings page alike.
@MainActor
@Observable
final class ProfileModel {
    enum Load: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let session: Session

    private(set) var profile: UserProfile?
    private(set) var profileLoad: Load = .idle
    private(set) var status: OwnStatus?
    private(set) var predefinedStatuses: [PredefinedStatus] = []
    /// What the server's status app offers. Nil hides status everywhere.
    ///
    /// Starts from the account's stored capabilities and is replaced by a fresh read on the
    /// first load: an account signed in before status was parsed has none stored, and would
    /// otherwise not see status until the server's Talk configuration next changed.
    private(set) var statusSupport: UserStatusSupport?
    /// Bumped when the picture changes, so every view showing it asks again.
    private(set) var avatarRevision = 0

    init(session: Session) {
        self.session = session
        statusSupport = session.account.capabilities.userStatus
    }

    var userID: String { session.account.userID }

    var displayName: String {
        profile?.displayName ?? session.account.resolvedDisplayName
    }

    var links: ProfileLinks { session.profileLinks }

    /// Everything, at once. Called when Settings opens and whenever the app comes back to
    /// the front while it is open — which is what brings in an edit made in the browser.
    func load() async {
        if profile == nil { profileLoad = .loading }
        async let profileResult = loadProfile()
        async let statusResult: Void = loadStatus()
        _ = await (profileResult, statusResult)
    }

    /// Just the status, for the sidebar's dot at launch.
    func loadStatus() async {
        if let fresh = try? await session.capabilities.capabilities(force: false) {
            statusSupport = fresh.userStatus
        }
        guard statusSupport != nil else {
            status = nil
            return
        }
        let service = session.userStatus
        async let current = try? service.status()
        async let predefined = try? service.predefinedStatuses()
        if let current = await current { status = current }
        if let predefined = await predefined { predefinedStatuses = predefined }
    }

    private func loadProfile() async {
        do {
            profile = try await session.profile.profile()
            profileLoad = .loaded
        } catch {
            // Keep what was already shown; say so only when there was nothing to show.
            profileLoad = profile == nil ? .failed(error.userMessage) : .loaded
            Log.ui.warning("Couldn’t load the profile: \(error.userMessage)")
        }
    }

    /// The message to show for the current status: a custom one as written, a predefined one
    /// by looking up its text, since the server sends only the id for those.
    var statusMessage: (icon: String, text: String)? {
        guard let status else { return nil }
        if status.messageIsPredefined, let id = status.messageID,
           let predefined = predefinedStatuses.first(where: { $0.id == id }) {
            return (predefined.icon, predefined.message)
        }
        let text = status.message ?? ""
        let icon = status.icon ?? ""
        guard !text.isEmpty || !icon.isEmpty else { return nil }
        return (icon, text)
    }
}
