import Foundation

/// The calendar app's out-of-office endpoints, which live in `dav`, not in Talk.
actor AbsenceService {
    private let client: OCSClient

    init(client: OCSClient) {
        self.client = client
    }

    /// Their absence if they're away right now; nil if they aren't, or never set one.
    func currentAbsence(userID: String) async throws(TalkError) -> Absence? {
        do throws(TalkError) {
            let response = try await client.send(OCSRequest.get(Endpoint.outOfOfficeNow(userID)), as: AbsenceDTO.self)
            return response.value?.model()
        } catch .notFound {
            return nil
        }
    }
}

struct AbsenceDTO: Decodable, Sendable {
    let userId: String?
    let startDate: Int?
    let endDate: Int?
    let shortMessage: String?
    let message: String?
    let replacementUserId: String?
    let replacementUserDisplayName: String?

    private enum CodingKeys: String, CodingKey {
        case userId, startDate, endDate, shortMessage, message, replacementUserId, replacementUserDisplayName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = Lenient.string(container, .userId)
        startDate = Lenient.int(container, .startDate)
        endDate = Lenient.int(container, .endDate)
        shortMessage = try? container.decodeIfPresent(String.self, forKey: .shortMessage)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        replacementUserId = try? container.decodeIfPresent(String.self, forKey: .replacementUserId)
        replacementUserDisplayName = try? container.decodeIfPresent(String.self, forKey: .replacementUserDisplayName)
    }

    func model() -> Absence? {
        guard let userId, let startDate, let endDate else { return nil }
        return Absence(
            userID: userId,
            start: Date(timeIntervalSince1970: TimeInterval(startDate)),
            end: Date(timeIntervalSince1970: TimeInterval(endDate)),
            shortMessage: shortMessage ?? "",
            message: message ?? "",
            replacementUserID: replacementUserId.flatMap { $0.isEmpty ? nil : $0 },
            replacementDisplayName: replacementUserDisplayName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
