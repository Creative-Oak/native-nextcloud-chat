import SwiftUI

/// Breakout rooms, said over the conversation, one line:
///
/// - in a breakout room: which it is and whose, a way to ask the moderators for help, and the
///   way back to the main conversation;
/// - in the main conversation while they run: for moderators, that they are running, any room
///   asking for help, and Stop; for everyone else, the way to their room — or, where people
///   choose, a room to choose.
struct BreakoutBar: View {
    let conversation: Conversation
    /// Its rooms, as the conversation list has them — every one for a moderator, theirs for
    /// anyone else.
    let rooms: [Conversation]
    /// The main conversation, when this is a breakout room.
    let parent: Conversation?
    let model: BreakoutRoomsModel
    /// Opens a conversation this user is already in.
    var onOpen: (String) -> Void
    /// Opens one they have only just been put in, once the list has it.
    var onOpenNew: (String) async -> Void

    /// Whether there's anything to say.
    static func isShown(for conversation: Conversation) -> Bool {
        conversation.isBreakoutRoom || conversation.areBreakoutRoomsRunning
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 10))
                .foregroundStyle(.teal)
            if conversation.isBreakoutRoom {
                inRoom
            } else if conversation.isModerator {
                hosting
            } else {
                waitingToGo
            }
            if model.isWorking { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .glass(.panel, cornerRadius: 10)
        .help(model.problem ?? "")
    }

    // MARK: - In a room

    @ViewBuilder
    private var inRoom: some View {
        let whose = parent?.displayName ?? String(localized: "breakout room", comment: "Shown after a breakout room’s name when its main conversation isn’t known")
        Text("\(Text(conversation.displayName).fontWeight(.medium))\(Text(" · \(whose)").foregroundStyle(.secondary))")
            .lineLimit(1)
            .truncationMode(.tail)
        Spacer(minLength: 6)
        if conversation.isModerator {
            if conversation.isAskingForHelp {
                Text("Asking for help")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
                    .fixedSize()
                Button("Done") { Task { await model.askForHelp(false, roomToken: conversation.token) } }
                    .buttonStyle(.link)
                    .fixedSize()
                    .help("You’ve helped them: take the request down")
            }
        } else if conversation.isAskingForHelp {
            Button("Help Asked · Cancel") { Task { await model.askForHelp(false, roomToken: conversation.token) } }
                .buttonStyle(.link)
                .fixedSize()
                .help("A moderator has been asked to come. Take the request back")
        } else {
            Button("Ask for Help") { Task { await model.askForHelp(true, roomToken: conversation.token) } }
                .buttonStyle(.link)
                .fixedSize()
                .help("Let the moderators know this room would like one of them to come")
        }
        if let parent {
            Button("Back to \(parent.displayName)") { onOpen(parent.token) }
                .buttonStyle(.link)
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: - The main conversation

    @ViewBuilder
    private var hosting: some View {
        let asking = rooms.filter(\.isAskingForHelp)
        if let first = asking.first {
            let name = Text(first.displayName).fontWeight(.medium)
            // "(+2)": how many more rooms ask for help.
            (asking.count > 1 ? Text("\(name) asks for help (+\(asking.count - 1))") : Text("\(name) asks for help"))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Button("Go") { onOpen(first.token) }
                .buttonStyle(.link)
                .fixedSize()
        } else {
            Text("Breakout rooms are running")
                .fontWeight(.medium)
                .lineLimit(1)
        }
        Spacer(minLength: 6)
        Button("Stop") { Task { await model.stop() } }
            .buttonStyle(.link)
            .fixedSize()
            .help("Close the rooms, and bring everyone back here")
    }

    @ViewBuilder
    private var waitingToGo: some View {
        Text("Breakout rooms are open")
            .fontWeight(.medium)
            .lineLimit(1)
        Spacer(minLength: 6)
        if conversation.breakoutRoomMode == .free {
            Menu("Choose a Room") {
                ForEach(model.fetchedRooms) { room in
                    Button(room.displayName) {
                        Task {
                            if let token = await model.choose(room) { await onOpenNew(token) }
                        }
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.link)
            .fixedSize()
            .task { await model.loadRooms() }
        } else if let mine = rooms.first {
            Button("Go to \(mine.displayName)") { onOpen(mine.token) }
                .buttonStyle(.link)
                .fixedSize()
        }
    }
}
