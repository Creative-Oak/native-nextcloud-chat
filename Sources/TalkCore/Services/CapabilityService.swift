import Foundation

/// Fetches and caches ``TalkCapabilities`` for an account.
///
/// Capabilities are refetched when the server's `X-Nextcloud-Talk-Hash` changes, which is
/// the documented signal that the Talk configuration moved — not on a timer, and never
/// inferred from a version number.
actor CapabilityService {
    private let client: OCSClient
    private var cached: TalkCapabilities?
    private var cachedHash: String?

    init(client: OCSClient) {
        self.client = client
    }

    /// - Parameter force: bypass the cache (used when the Talk hash changed).
    func capabilities(force: Bool = false) async throws(TalkError) -> TalkCapabilities {
        if !force, let cached { return cached }

        let response = try await client.require(OCSRequest.get(Endpoint.capabilities), as: CapabilitiesDTO.self)
        guard let capabilities = response.value.talkCapabilities() else {
            throw .missingCapability("Nextcloud Talk")
        }

        cached = capabilities
        cachedHash = response.headers.talkHash
        Log.api.info("Talk \(capabilities.talkVersion ?? "?") on Nextcloud \(capabilities.serverVersion.string): \(capabilities.features.count) capabilities")
        return capabilities
    }

    /// Called when a Talk response carried a different hash than the one we fetched with.
    func invalidate(newHash: String?) {
        guard newHash != cachedHash else { return }
        cached = nil
        cachedHash = nil
    }

    func cachedCapabilities() -> TalkCapabilities? { cached }

    func preload(_ capabilities: TalkCapabilities, hash: String?) {
        cached = capabilities
        cachedHash = hash
    }
}
