import Foundation
import Observation

/// Breakout rooms for the open conversation: setting them up, starting and stopping them,
/// messaging all of them — for its moderators — and, for everyone else, getting to their room
/// and asking for help from there. See ``BreakoutRoomService``.
///
/// Which rooms there are, and whether one is asking for help, comes from the conversation
/// list, which has every room this user is in and updates live. Only the free mode's picker
/// needs rooms this user isn't in yet; it fetches them.
@MainActor
@Observable
final class BreakoutRoomsModel {
    /// Every room there is, fetched — for choosing one in the free mode.
    private(set) var fetchedRooms: [Conversation] = []
    /// The conversation's people, for putting them in rooms by hand.
    private(set) var people: [Participant] = []
    private(set) var isWorking = false
    /// What went wrong last, said where it was asked for.
    var problem: String?

    let token: String
    private let session: Session

    init(session: Session, token: String) {
        self.session = session
        self.token = token
    }

    private var service: BreakoutRoomService { session.breakoutRooms }

    // MARK: - Moderators

    func setUp(mode: BreakoutRoomMode, amount: Int, assignments: [Int: Int]) async -> Bool {
        await run({ String(localized: "Couldn’t set up the breakout rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in
            _ = try await service.setUp(token: token, mode: mode, amount: amount, assignments: assignments)
        }
    }

    func rearrange(_ assignments: [Int: Int]) async -> Bool {
        await run({ String(localized: "Couldn’t move people between rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in
            _ = try await service.reassign(token: token, assignments: assignments)
        }
    }

    func start() async {
        await run({ String(localized: "Couldn’t start the breakout rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in _ = try await service.start(token: token) }
    }

    func stop() async {
        await run({ String(localized: "Couldn’t stop the breakout rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in _ = try await service.stop(token: token) }
    }

    func remove() async {
        await run({ String(localized: "Couldn’t delete the breakout rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in try await service.remove(token: token) }
    }

    func broadcast(_ message: String) async -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await run({ String(localized: "Couldn’t send the message to the rooms: \($0)", comment: "%@ is the reason") }) { [service, token] () async throws(TalkError) in try await service.broadcast(text, token: token) }
    }

    /// Who is in which room now, as attendee id to room number — rooms numbered in the order
    /// the server made them, which is the order it reads room numbers in. People are matched
    /// by who they are: an attendee id belongs to one conversation.
    func currentAssignments(in rooms: [Conversation]) async -> [Int: Int] {
        var assignments: [Int: Int] = [:]
        for (number, room) in rooms.sorted(by: { $0.numericID < $1.numericID }).enumerated() {
            guard let inRoom = try? await session.participants.participants(token: room.token, includeStatus: false) else { continue }
            for member in inRoom {
                if let person = people.first(where: { $0.actor.kind == member.actor.kind && $0.actor.id == member.actor.id }) {
                    assignments[person.attendeeID] = number
                }
            }
        }
        return assignments
    }

    /// The people a moderator can put in rooms: everyone but the moderators, who are in all
    /// of them anyway.
    func loadPeople() async {
        do throws(TalkError) {
            people = try await session.participants.participants(token: token, includeStatus: false)
                .filter { !$0.participantType.isModerator }
                .sorted { $0.actor.resolvedDisplayName.localizedStandardCompare($1.actor.resolvedDisplayName) == .orderedAscending }
        } catch {
            problem = String(localized: "Couldn’t get the conversation’s people: \(error.userMessage)", comment: "%@ is the reason")
        }
    }

    // MARK: - Everyone

    /// The free mode's rooms, to choose from.
    func loadRooms() async {
        do throws(TalkError) {
            fetchedRooms = try await service.rooms(token: token)
        } catch {
            Log.ui.info("Couldn’t list the breakout rooms: \(error.userMessage)")
        }
    }

    /// The free mode: into `room`, out of any other. The room's token, to open, once it worked.
    func choose(_ room: Conversation) async -> String? {
        let ok = await run({ String(localized: "Couldn’t go to \(room.displayName): \($0)", comment: "First %@ is a breakout room's name, second the reason") }) { [service, token] () async throws(TalkError) in
            _ = try await service.switchTo(room.token, token: token)
        }
        return ok ? room.token : nil
    }

    /// From inside a breakout room — `roomToken` — the moderators are asked to come. `false`
    /// takes it back, or, for a moderator, marks it dealt with.
    func askForHelp(_ asking: Bool, roomToken: String) async {
        await run({
            asking
                ? String(localized: "Couldn’t ask for help: \($0)", comment: "%@ is the reason")
                : String(localized: "Couldn’t take back the request for help: \($0)", comment: "%@ is the reason")
        }) { [service] () async throws(TalkError) in
            try await service.askForHelp(asking, roomToken: roomToken)
        }
    }

    // MARK: -

    /// `failure` says what went wrong, given the reason.
    /// - Returns: whether it worked.
    @discardableResult
    private func run(_ failure: (String) -> String, _ work: @escaping @Sendable () async throws(TalkError) -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        problem = nil
        do throws(TalkError) {
            try await work()
            // Rooms made, gone, opened or closed: the list, and with it the bars, now.
            await session.conversationSync.refreshNow(full: true)
            return true
        } catch {
            let problem = failure(error.userMessage)
            Log.ui.warning("Breakout rooms: \(problem)")
            self.problem = problem
            return false
        }
    }
}

extension Conversation {
    /// Whether this is one of `parent`'s breakout rooms.
    func isBreakoutRoom(of parent: String) -> Bool {
        breakoutParentToken == parent
    }

    var isAskingForHelp: Bool {
        isBreakoutRoom && breakoutRoomStatus == .assistanceRequested
    }
}
