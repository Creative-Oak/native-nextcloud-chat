import Foundation

/// Someone's out-of-office, as they set it in Nextcloud — what Talk's web app shows at the
/// top of a one-to-one conversation.
struct Absence: Sendable, Hashable {
    var userID: String
    var start: Date
    var end: Date
    var shortMessage: String
    var message: String
    /// Who to ask instead, if they said.
    var replacementUserID: String?
    var replacementDisplayName: String?

    /// The last day they're away, for "until Friday". The end is where the absence stops,
    /// so the day that contains it is only counted when it isn't exactly its start.
    func lastDay(calendar: Calendar = .current) -> Date {
        let startOfEndDay = calendar.startOfDay(for: end)
        return end == startOfEndDay ? end.addingTimeInterval(-1) : end
    }
}

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
