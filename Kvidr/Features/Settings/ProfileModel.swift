import Foundation
import Observation

/// The signed-in user as Nextcloud has them: profile, status, and whether the server lets
/// status be set at all.
///
/// One per session, read by the sidebar's account row and the Settings page alike.
@MainActor
@Observable
final class ProfileModel {
    /// Where a change stands, for the spinner, the checkmark or the reason beside it.
    enum Save: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

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

    private(set) var statusSave: Save = .idle
    private(set) var pictureSave: Save = .idle

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

    // MARK: - Status

    /// Shown at once, sent, and put back with the server's reason if it is refused. Nothing
    /// is queued: a status set while offline would arrive at the wrong moment.
    func setStatus(_ new: OnlineStatus) async {
        let previous = status ?? .unset
        guard previous.status != new else { return }
        var optimistic = previous
        optimistic.status = new
        status = optimistic
        await save(restoring: previous) { (service: UserStatusService) async throws(TalkError) -> OwnStatus in try await service.setStatus(new) }
    }

    /// A message of the user's own. Nothing in either field clears the message instead.
    func setMessage(icon: String, text: String, clearAfter: ClearAfter) async {
        let icon = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !icon.isEmpty || !text.isEmpty else {
            await clearMessage()
            return
        }
        let previous = status ?? .unset
        var optimistic = previous
        optimistic.icon = icon
        optimistic.message = text
        optimistic.messageID = nil
        optimistic.messageIsPredefined = false
        optimistic.clearAt = clearAfter.date(from: .now)
        status = optimistic
        let clearAt = optimistic.clearAt
        await save(restoring: previous) { (service: UserStatusService) async throws(TalkError) -> OwnStatus in
            try await service.setCustomMessage(icon: icon, message: text, clearAt: clearAt)
        }
    }

    func applyPredefined(_ predefined: PredefinedStatus) async {
        let previous = status ?? .unset
        var optimistic = previous
        optimistic.icon = predefined.icon
        optimistic.message = predefined.message
        optimistic.messageID = predefined.id
        optimistic.messageIsPredefined = true
        optimistic.clearAt = predefined.clearAfter.date(from: .now)
        status = optimistic
        let clearAt = optimistic.clearAt
        await save(restoring: previous) { (service: UserStatusService) async throws(TalkError) -> OwnStatus in
            try await service.setPredefinedMessage(id: predefined.id, clearAt: clearAt)
        }
    }

    func clearMessage() async {
        let previous = status ?? .unset
        guard previous.hasMessage else { return }
        var optimistic = previous
        optimistic.icon = nil
        optimistic.message = nil
        optimistic.messageID = nil
        optimistic.messageIsPredefined = false
        optimistic.clearAt = nil
        status = optimistic
        await save(restoring: previous) { (service: UserStatusService) async throws(TalkError) -> OwnStatus in
            try await service.clearMessage()
            return optimistic
        }
    }

    private func save(
        restoring previous: OwnStatus,
        _ change: (UserStatusService) async throws(TalkError) -> OwnStatus
    ) async {
        statusSave = .saving
        do {
            status = try await change(session.userStatus)
            settle(\.statusSave)
        } catch {
            status = previous
            statusSave = .failed(error.userMessage)
        }
    }

    // MARK: - Picture

    /// What a picture file becomes before it is shown for confirmation: read where a dead
    /// share can't hang the window, then squared and encoded off the main actor.
    static func preparePicture(from url: URL) async throws(TalkError) -> Data {
        // The server refuses anything over twenty megabytes; a photo larger than that
        // would be refused after the work of squaring it.
        let original = try await FileInspection.read(url, maximumBytes: 20 * 1024 * 1024)
        let squared = await Task.detached(priority: .userInitiated) { () -> Data? in
            try? SquareAvatar.png(from: original)
        }.value
        guard let squared else { throw .fileNotAPicture }
        return squared
    }

    /// Returns whether it took, so the confirmation sheet knows whether to close.
    func setPicture(png: Data, avatarLoader: AvatarLoader?) async -> Bool {
        pictureSave = .saving
        do {
            try await session.profile.setAvatar(png: png)
            await avatarLoader?.forget(userID: userID)
            settle(\.pictureSave)
            return true
        } catch {
            pictureSave = .failed(error.userMessage)
            return false
        }
    }

    func removePicture(avatarLoader: AvatarLoader?) async {
        pictureSave = .saving
        do {
            try await session.profile.removeAvatar()
            await avatarLoader?.forget(userID: userID)
            settle(\.pictureSave)
        } catch {
            pictureSave = .failed(error.userMessage)
        }
    }

    func resetPictureSave() {
        pictureSave = .idle
    }

    /// A checkmark for a moment, then nothing.
    private func settle(_ keyPath: ReferenceWritableKeyPath<ProfileModel, Save>) {
        self[keyPath: keyPath] = .saved
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self[keyPath: keyPath] == .saved else { return }
            self[keyPath: keyPath] = .idle
        }
    }
}
