import Foundation

/// `GET /ocs/v2.php/cloud/capabilities`.
///
/// Decoded defensively: every field is optional, because the whole point of this endpoint
/// is that different servers expose different things. A missing `spreed` section means
/// Talk is not installed, which is a first-class outcome, not a decoding failure.
struct CapabilitiesDTO: Decodable, Sendable {
    let version: VersionDTO?
    let capabilities: CapabilitiesBody?

    struct VersionDTO: Decodable, Sendable {
        let major: Int?
        let minor: Int?
        let micro: Int?
        let string: String?
        let edition: String?
    }

    struct CapabilitiesBody: Decodable, Sendable {
        let spreed: SpreedDTO?
    }

    struct SpreedDTO: Decodable, Sendable {
        let features: [String]?
        let featuresLocal: [String]?
        let config: ConfigDTO?
        let version: String?

        private enum CodingKeys: String, CodingKey {
            case features
            case featuresLocal = "features-local"
            case config
            case version
        }
    }

    struct ConfigDTO: Decodable, Sendable {
        let chat: ChatConfigDTO?
        let attachments: AttachmentsConfigDTO?
        let conversations: ConversationsConfigDTO?
        let previews: PreviewsConfigDTO?
        let call: CallConfigDTO?
    }

    struct ChatConfigDTO: Decodable, Sendable {
        let maxLength: Int?
        let readPrivacy: Int?
        let typingPrivacy: Int?

        private enum CodingKeys: String, CodingKey {
            case maxLength = "max-length"
            case readPrivacy = "read-privacy"
            case typingPrivacy = "typing-privacy"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxLength = Lenient.int(container, .maxLength)
            readPrivacy = Lenient.int(container, .readPrivacy)
            typingPrivacy = Lenient.int(container, .typingPrivacy)
        }
    }

    struct AttachmentsConfigDTO: Decodable, Sendable {
        let allowed: Bool?
        let folder: String?

        private enum CodingKeys: String, CodingKey { case allowed, folder }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            allowed = Lenient.bool(container, .allowed)
            folder = Lenient.string(container, .folder)
        }
    }

    struct ConversationsConfigDTO: Decodable, Sendable {
        let canCreate: Bool?

        private enum CodingKeys: String, CodingKey { case canCreate = "can-create" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            canCreate = Lenient.bool(container, .canCreate)
        }
    }

    struct PreviewsConfigDTO: Decodable, Sendable {
        let maxGIFSize: Int?

        private enum CodingKeys: String, CodingKey { case maxGIFSize = "max-gif-size" }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            maxGIFSize = Lenient.int(container, .maxGIFSize)
        }
    }

    struct CallConfigDTO: Decodable, Sendable {
        let enabled: Bool?

        private enum CodingKeys: String, CodingKey { case enabled }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = Lenient.bool(container, .enabled)
        }
    }

    /// Maps onto the app's capability model. Returns `nil` when Talk isn't installed.
    func talkCapabilities() -> TalkCapabilities? {
        guard let spreed = capabilities?.spreed else { return nil }

        var features = Set(spreed.features ?? [])
        // `features-local` lists capabilities that apply to local (non-federated)
        // conversations. For gating local UI they count exactly the same.
        features.formUnion(spreed.featuresLocal ?? [])

        let config = TalkConfig(
            chatMaxLength: spreed.config?.chat?.maxLength,
            chatReadPrivacy: spreed.config?.chat?.readPrivacy,
            chatTypingPrivacy: spreed.config?.chat?.typingPrivacy,
            attachmentsAllowed: spreed.config?.attachments?.allowed,
            attachmentsFolder: spreed.config?.attachments?.folder,
            conversationsCanCreate: spreed.config?.conversations?.canCreate,
            previewsMaxGIFSize: spreed.config?.previews?.maxGIFSize,
            callEnabled: spreed.config?.call?.enabled
        )

        return TalkCapabilities(
            features: features,
            config: config,
            talkVersion: spreed.version,
            serverVersion: ServerVersion(
                major: version?.major ?? 0,
                minor: version?.minor ?? 0,
                micro: version?.micro ?? 0,
                string: version?.string ?? "unknown",
                edition: version?.edition ?? ""
            )
        )
    }
}

/// `GET /ocs/v2.php/cloud/user`
struct UserDTO: Decodable, Sendable {
    let id: String
    let displayName: String?
    let email: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display-name"
        case displaynameAlternate = "displayname"
        case email
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Nextcloud has shipped both spellings over the years.
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? container.decodeIfPresent(String.self, forKey: .displaynameAlternate)
        email = try? container.decodeIfPresent(String.self, forKey: .email)
    }
}
