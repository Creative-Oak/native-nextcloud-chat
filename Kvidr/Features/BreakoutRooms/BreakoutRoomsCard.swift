import SwiftUI

/// In the inspector, for a conversation's moderators: its breakout rooms — setting them up,
/// the rooms themselves with any asking for help, and starting, stopping, messaging all of
/// them, moving people between them and deleting them.
struct BreakoutRoomsCard: View {
    let conversation: Conversation
    let rooms: [Conversation]
    let model: BreakoutRoomsModel
    var onOpen: (String) -> Void

    @State private var isSettingUp = false
    @State private var isRearranging = false
    @State private var isBroadcasting = false
    @State private var broadcastText = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        InspectorCard(title: "Breakout Rooms") {
            if !conversation.hasBreakoutRooms {
                Text("Split the conversation into smaller rooms for a while — for group work, say — and bring everyone back when you’re done.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InspectorActionRow(title: "Set Up Breakout Rooms…") { isSettingUp = true }
            } else {
                ForEach(rooms) { room in
                    roomRow(room)
                }
                InspectorActionRow(title: conversation.areBreakoutRoomsRunning ? "Stop Breakout Rooms" : "Start Breakout Rooms") {
                    Task { conversation.areBreakoutRoomsRunning ? await model.stop() : await model.start() }
                }
                InspectorActionRow(title: "Message All Rooms…") { isBroadcasting = true }
                if conversation.breakoutRoomMode == .manual {
                    InspectorActionRow(title: "Move People…") { isRearranging = true }
                }
                InspectorActionRow(title: "Delete Breakout Rooms…", role: .destructive) { isConfirmingDelete = true }
            }
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isSettingUp) {
            BreakoutSetupSheet(model: model, rooms: nil)
        }
        .sheet(isPresented: $isRearranging) {
            BreakoutSetupSheet(model: model, rooms: rooms)
        }
        .alert("Message All Rooms", isPresented: $isBroadcasting) {
            TextField("Message", text: $broadcastText)
            Button("Send") {
                let text = broadcastText
                broadcastText = ""
                Task { _ = await model.broadcast(text) }
            }
            Button("Cancel", role: .cancel) { broadcastText = "" }
        } message: {
            Text("It’s posted in every breakout room, in your name.")
        }
        .confirmationDialog("Delete the breakout rooms?", isPresented: $isConfirmingDelete) {
            Button("Delete Breakout Rooms", role: .destructive) { Task { await model.remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every room goes, with what was written in it. Everyone stays in this conversation.")
        }
    }

    private func roomRow(_ room: Conversation) -> some View {
        Button { onOpen(room.token) } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x2")
                    .foregroundStyle(.teal)
                Text(room.displayName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if room.isAskingForHelp {
                    Label("Asking for help", systemImage: "hand.raised.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open \(room.displayName)")
    }
}

/// Setting breakout rooms up — how many, and how people get into them — or, with `rooms`,
/// moving people between the ones there are.
struct BreakoutSetupSheet: View {
    let model: BreakoutRoomsModel
    /// The rooms there are, when moving people between them; nil when setting up.
    let rooms: [Conversation]?

    @Environment(\.dismiss) private var dismiss
    @State private var amount = 2
    @State private var mode: BreakoutRoomMode = .automatic
    /// Attendee id to room number, from 0.
    @State private var assignments: [Int: Int] = [:]
    @State private var isLoading = true

    private var isSettingUp: Bool { rooms == nil }
    private var roomCount: Int { rooms?.count ?? amount }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isSettingUp ? "Set Up Breakout Rooms" : "Move People").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                if isSettingUp {
                    Section {
                        Stepper("\(amount) \(amount == 1 ? "room" : "rooms")", value: $amount, in: 1...20)
                        Picker("People", selection: $mode) {
                            Text("Spread out automatically").tag(BreakoutRoomMode.automatic)
                            Text("Put in rooms by you").tag(BreakoutRoomMode.manual)
                            Text("Choose a room themselves").tag(BreakoutRoomMode.free)
                        }
                        .pickerStyle(.radioGroup)
                        Text("Moderators are in every room. The rooms open when you start them, and everyone in this conversation is moved into theirs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !isSettingUp || mode == .manual {
                    Section("Who goes where") {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else if model.people.isEmpty {
                            Text("There’s nobody to put in a room — only moderators are here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.people) { person in
                            Picker(person.actor.resolvedDisplayName, selection: room(for: person)) {
                                Text("No room").tag(-1)
                                ForEach(0..<roomCount, id: \.self) { number in
                                    Text(roomName(number)).tag(number)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSettingUp ? "Create Rooms" : "Move") {
                    Task {
                        let done = isSettingUp
                            ? await model.setUp(mode: mode, amount: amount, assignments: assignments)
                            : await model.rearrange(assignments)
                        if done { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: 480)
        .task {
            model.problem = nil
            await model.loadPeople()
            if let rooms { assignments = await model.currentAssignments(in: rooms) }
            isLoading = false
        }
        // Fewer rooms: whoever was in one that's gone isn't in a room any more.
        .onChange(of: amount) { _, count in
            assignments = assignments.filter { $0.value < count }
        }
    }

    private func room(for person: Participant) -> Binding<Int> {
        Binding(
            get: { assignments[person.attendeeID] ?? -1 },
            set: { assignments[person.attendeeID] = $0 < 0 ? nil : $0 }
        )
    }

    /// The server calls them Room 1, Room 2, …; the ones there are keep the names they have.
    private func roomName(_ number: Int) -> String {
        guard let rooms else { return "Room \(number + 1)" }
        let ordered = rooms.sorted { $0.numericID < $1.numericID }
        return number < ordered.count ? ordered[number].displayName : "Room \(number + 1)"
    }
}
