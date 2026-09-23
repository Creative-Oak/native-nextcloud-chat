import CoreAudio
import SwiftUI

/// The call, FaceTime-style: dark, edge to edge, the people in it large, you small in a
/// corner, and the controls floating over the bottom as glass. It slides in from the leading
/// edge and the conversation moves over to a column beside it — the chat is still there,
/// just narrower, so the call reads as the conversation turned into one.
struct CallStage: View {
    let call: CallController
    let me: MessageActor
    var onLeave: () -> Void
    /// Hangs up the other way: leaving without ending, or ending for everyone.
    var onLeaveTheOtherWay: () -> Void = {}
    var onDismiss: () -> Void
    /// Shrinks the call to a pill, back to the messages.
    var onMinimize: () -> Void
    /// The call's notes, into the conversation's field to read over and send.
    var onUseInChat: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Everyone in the call, in a panel beside the stage.
    @State private var showsPeople = false
    /// The notes so far, in a panel over the stage.
    @State private var showsNotes = false

    var body: some View {
        ZStack {
            switch call.phase {
            case .ended(let reason):
                ended(reason: reason)
            case .joining, .inCall:
                stage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A background, not a layer of the stack: the wash is a 900-point picture, and as a
        // layer it made the stage 900 points tall in a shorter window — centred, with the
        // header and the controls cut off above and below.
        .background { backdrop }
        .environment(\.colorScheme, .dark)
        .clipped()
    }

    // MARK: - Pieces

    /// Behind everything: one other person's video, filling the window as in FaceTime; or,
    /// with no video, their picture — or the conversation's — blown up into a soft wash of
    /// its own colours, the way the iPhone's call screen fills with a poster.
    private var backdrop: some View {
        ZStack {
            Color(white: 0.06)
            if let video = soloVideo {
                VideoView(video: video)
                    .transition(.opacity)
            } else {
                Group {
                    if let solo = soloParticipant {
                        ActorAvatarView(actor: solo.actor, size: 900)
                    } else {
                        AvatarView(conversation: call.conversation, size: 900)
                    }
                }
                .blur(radius: 140)
                .saturation(1.6)
                .opacity(0.9)
                .accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.3), value: soloVideo)
    }

    /// The only other person in the call, when there is exactly one.
    private var soloParticipant: CallController.Participant? {
        call.participants.count == 1 ? call.participants.first : nil
    }

    /// The video of the only other person, when there is one and their camera is on.
    private var soloVideo: VideoTrack? {
        // A shared screen has the stage; the backdrop stays dark behind it.
        if call.sharedScreen != nil || call.localScreen != nil { return nil }
        guard call.participants.count == 1, let only = call.participants.first, only.isVideoOn else { return nil }
        return only.video
    }

    private var stage: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 52)
                .padding(.horizontal, 24)

            if let problem = call.cameraProblem {
                Label(problem, systemImage: "video.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.35), in: .capsule)
                    .padding(.top, 10)
            }
            if call.audioDevices.inputs.isEmpty {
                Label("No microphone — connect one, like your AirPods, to be heard.", systemImage: "mic.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.35), in: .capsule)
                    .padding(.top, 10)
            }

            if call.isSharingScreen {
                Button(action: call.stopSharingScreen) {
                    Label("You’re sharing your screen · Stop", systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.green, in: .capsule)
                }
                .buttonStyle(.plain)
                .help("Stop sharing your screen")
                .padding(.top, 10)
            }

            Group {
                if let shared = call.sharedScreen {
                    // Someone's screen: all of it, as large as the stage allows, with who.
                    VStack(spacing: 8) {
                        VideoView(video: shared.screen, fits: true)
                        Label("\(shared.participant.name)’s screen", systemImage: "rectangle.on.rectangle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if let own = call.localScreen {
                    // What this Mac is sharing, shown back while kvidr is in front.
                    VStack(spacing: 8) {
                        VideoView(video: own, fits: true)
                        Label("Your screen", systemImage: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                } else if call.participants.isEmpty {
                    waiting
                } else if soloVideo != nil {
                    // Their video is the backdrop, and their name is already at the top.
                    Color.clear
                } else if let only = soloParticipant {
                    // No video: their picture, large, as the iPhone shows whoever you're talking
                    // to — smaller in a short window, so the controls never go off the bottom.
                    ViewThatFits(in: .vertical) {
                        soloPicture(only, size: 200)
                        soloPicture(only, size: 120)
                        soloPicture(only, size: 64)
                    }
                } else {
                    tiles
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                if let notice = call.notice {
                    Label(notice.text, systemImage: notice.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(notice.id)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: call.notice)
            .overlay {
                ReactionsOverlay(reactions: call.reactions)
                    .padding(.leading, 40)
                    .padding(.bottom, 24)
            }
            .overlay(alignment: .bottom) {
                CaptionsView(captions: call.captions)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
            }

            controls
                .padding(.bottom, 22)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onMinimize) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .help("Minimize the call, and keep talking while you use kvidr")
            .accessibilityLabel("Minimize the call")
            .padding(.leading, 20)
            .padding(.top, 50)
        }
        // Everyone in the call, opposite the minimize button — a hand that's up shows here too.
        .overlay(alignment: .topTrailing) {
            Button { showsPeople.toggle() } label: {
                Image(systemName: showsPeople ? "person.2.fill" : "person.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showsPeople ? .black : .white)
                    .frame(width: 36, height: 36)
                    .background {
                        if showsPeople { Circle().fill(.white) }
                    }
                    .glassEffect(showsPeople ? .identity : .regular.interactive(), in: .circle)
                    .overlay(alignment: .topTrailing) {
                        if call.participants.contains(where: \.isHandRaised) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 16, height: 16)
                                .background(.yellow, in: .circle)
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help(showsPeople ? "Hide who's in the call (⇧⌘P)" : "Who's in the call (⇧⌘P)")
            .accessibilityLabel("People in the Call")
            .accessibilityValue(showsPeople ? "Shown" : "Hidden")
            .padding(.trailing, 20)
            .padding(.top, 50)
        }
        .overlay {
            MovableSelfTile(me: me, isMuted: call.isMuted, isSpeaking: call.isSpeaking, isHandRaised: call.isHandRaised, video: call.isCameraOn ? call.localVideo : nil)
        }
        .overlay(alignment: .topTrailing) {
            if showsPeople {
                CallPeoplePanel(call: call, me: me) { showsPeople = false }
                    .padding(.trailing, 16)
                    .padding(.top, 96)
                    .padding(.bottom, 110)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: showsPeople)
        .overlay(alignment: .top) {
            if showsNotes, call.summary.state != .idle {
                CallNotesView(summary: call.summary, title: notesTitle, onUseInChat: onUseInChat)
                    .overlay(alignment: .topTrailing) {
                        Button { showsNotes = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .accessibilityLabel("Close the notes")
                    }
                    .padding(.top, 150)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: showsNotes)
        // Your own hand, said where you'll see it, with the way to put it down.
        .overlay(alignment: .bottom) {
            if call.isHandRaised {
                Button(action: call.toggleHand) {
                    Label("Your hand is raised · Lower", systemImage: "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.yellow, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 118)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: call.isHandRaised)
    }

    /// The iPhone's order: how long, small, over who — large.
    /// Their picture, still ringing until their audio arrives, then still, with a note that
    /// it's their camera that's off, not the call that hasn't started.
    private func soloPicture(_ only: CallController.Participant, size: CGFloat) -> some View {
        VStack(spacing: size >= 120 ? 18 : 10) {
            ZStack(alignment: .bottomTrailing) {
                ActorAvatarView(actor: only.actor, size: size)
                    .shadow(color: .black.opacity(0.25), radius: size / 8, y: size / 20)
                    .opacity(only.isConnected ? 1 : 0.7)
                    .speakingRing(only.isSpeaking, lineWidth: size >= 120 ? 4 : 3)
                    .overlay(alignment: .topLeading) {
                        if only.isHandRaised { HandBadge(size: size >= 120 ? 20 : 13) }
                    }
                    .background {
                        if !only.isConnected { RingingRings(diameter: size) }
                    }
                if !only.isAudioOn {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: size >= 120 ? 15 : 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: size / 5, height: size / 5)
                        .glassEffect(.regular, in: .circle)
                }
            }
            if only.isConnected {
                Label("Camera off", systemImage: "video.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: only.isConnected)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Group {
                if let since = call.answeredAt, !call.participants.isEmpty {
                    if let people = peopleInGroup {
                        // A group's name alone doesn't say who's there; how many does, a little.
                        Text("\(Text(since, style: .timer).monospacedDigit()) · \(people) people")
                    } else {
                        Text(since, style: .timer).monospacedDigit()
                    }
                } else if call.phase == .joining || !call.participants.isEmpty {
                    // Joining ourselves, or they've picked up and their audio is on its way.
                    Text("Connecting…")
                } else {
                    Text("Calling…")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 40, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if soloVideo != nil, soloParticipant?.isHandRaised == true {
                    HandBadge(size: 14)
                }
                // Muted, said where their name is — the tile that would say it isn't there.
                if soloVideo != nil, soloParticipant?.isAudioOn == false {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(soloVideo == nil ? 0 : 0.5), radius: 6)
    }

    /// Who the call is with: the other person in a one-to-one; a group's own name, however
    /// many of it have joined.
    private var title: String {
        if call.conversation.isOneToOne, let solo = soloParticipant { return solo.name }
        return call.conversation.displayName
    }

    /// Everyone in a group call, you included; nil in a one-to-one.
    private var peopleInGroup: Int? {
        call.conversation.isOneToOne ? nil : call.participants.count + 1
    }

    /// Nobody has picked up: their picture, with rings going out from it like a phone ringing.
    /// Smaller in a short window, as the one-to-one picture is.
    private var waiting: some View {
        ViewThatFits(in: .vertical) {
            ForEach([200, 120, 64] as [CGFloat], id: \.self) { size in
                AvatarView(conversation: call.conversation, size: size)
                    .shadow(color: .black.opacity(0.25), radius: size / 8, y: size / 20)
                    .background { RingingRings(diameter: size) }
            }
        }
    }

    /// Everyone, in tiles that fill the stage — larger the fewer there are. Someone joining
    /// or leaving makes the others slide to their new places.
    private var tiles: some View {
        FittedTileLayout(spacing: 14) {
            ForEach(call.participants) { participant in
                ParticipantTile(participant: participant)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: call.participants.map(\.id))
    }

    /// Round glass buttons with their names under them, as on the iPhone; white while what
    /// they do is on.
    private var controls: some View {
        HStack(alignment: .top, spacing: 26) {
            CallControlButton(
                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                title: "Mute",
                help: call.isMuted ? "Unmute (⇧⌘M)" : "Mute (⇧⌘M)",
                isActive: call.isMuted,
                action: call.toggleMute
            )
            .keyboardShortcut("m", modifiers: [.command, .shift])

            CallControlButton(
                symbol: call.isCameraOn ? "video.fill" : "video.slash.fill",
                title: "Camera",
                help: call.isCameraOn ? "Turn camera off (⇧⌘V)" : "Turn camera on (⇧⌘V)",
                isActive: call.isCameraOn,
                action: call.toggleCamera
            )
            .keyboardShortcut("v", modifiers: [.command, .shift])

            CallControlButton(
                symbol: call.isSharingScreen ? "rectangle.slash" : "rectangle.inset.filled.and.person.filled",
                title: "Share",
                help: call.isSharingScreen ? "Stop sharing your screen" : "Share your screen or a window",
                isActive: call.isSharingScreen,
                action: { call.isSharingScreen ? call.stopSharingScreen() : call.shareScreen() }
            )

            ReactButton(call: call)

            AudioDeviceMenu(
                onSummarize: call.captions.isOn ? {
                    call.summarizeSoFar()
                    showsNotes = true
                } : nil,
                captions: call.captions,
                devices: call.audioDevices,
                cameras: call.cameras.map { ($0.uniqueID, $0.localizedName) },
                cameraID: call.cameraID,
                onMicrophone: call.useMicrophone,
                onSpeaker: call.useSpeaker,
                onCamera: call.useCamera
            )

            VStack(spacing: 7) {
                Button(action: onLeave) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(.red, in: .circle)
                }
                .buttonStyle(.plain)
                .help(call.hangUpEndsCall ? "End the call" : "Leave the call")
                .accessibilityLabel(call.hangUpEndsCall ? "End the call" : "Leave the call")
                // The other way, a right-click away, as Talk's iPhone app has it on a long press.
                .contextMenu {
                    if call.canHangUpTheOtherWay {
                        Button(call.hangUpEndsCall ? "Leave Call" : "End Call for Everyone", systemImage: "phone.down.fill", action: onLeaveTheOtherWay)
                    }
                }
                CallButtonTitle("End")
            }
        }
    }

    /// What the notes are headed with, in the chat and on the clipboard.
    private var notesTitle: String {
        "Call notes · \(call.conversation.displayName) · \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    private func ended(reason: String?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "phone.down.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.8))
            Text(reason ?? "The call has ended.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Close", action: onDismiss)
                .keyboardShortcut(.defaultAction)
            // Captions ran: the notes are written while this shows.
            if call.summary.state != .idle {
                CallNotesView(summary: call.summary, title: notesTitle, onUseInChat: onUseInChat)
                    .padding(.top, 10)
            }
        }
    }
}

/// Someone else in the call: their video, or their picture on a dark card sized to the tile,
/// their name in the corner — FaceTime's tile.
private struct ParticipantTile: View {
    let participant: CallController.Participant

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
            if participant.isVideoOn, let video = participant.video {
                VideoView(video: video)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
            } else {
                GeometryReader { proxy in
                    // Their picture in proportion to the tile: small tiles in a big group, large
                    // ones with two or three people.
                    let side = min(max(min(proxy.size.width, proxy.size.height) * 0.42, 44), 150)
                    ActorAvatarView(actor: actor, size: side)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .opacity(participant.isConnected ? 1 : 0.55)
            }
            HStack(spacing: 6) {
                if !participant.isAudioOn {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(participant.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !participant.isConnected {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(12)
        }
        .overlay(alignment: .topLeading) {
            if participant.isHandRaised { HandBadge().padding(10) }
        }
        .speakingRing(participant.isSpeaking, cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var actor: MessageActor {
        MessageActor(type: participant.actorType ?? "users", id: participant.actorID ?? participant.userID ?? "", displayName: participant.name)
    }

    private var label: String {
        if !participant.isConnected { return "\(participant.name), connecting" }
        var label = participant.name
        if participant.isHandRaised { label += ", hand raised" }
        if participant.isSpeaking { label += ", speaking" }
        return label
    }
}

/// A call's tiles, placed by ``TileGrid``: all the same size, as large as the stage allows,
/// rows centred. Takes all the space it is offered.
private struct FittedTileLayout: Layout {
    var spacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 640, height: 480))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = TileGrid(count: subviews.count, in: bounds.size, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let center = grid.center(of: index)
            subview.place(
                at: CGPoint(x: bounds.minX + center.x, y: bounds.minY + center.y),
                anchor: .center,
                proposal: ProposedViewSize(grid.tileSize)
            )
        }
    }
}

/// You, small in the corner — where FaceTime puts your camera.
private struct SelfTile: View {
    let me: MessageActor
    let isMuted: Bool
    var isSpeaking = false
    var isHandRaised = false
    let video: VideoTrack?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.1))
            if let video {
                VideoView(video: video, isMirrored: true)
                    .clipShape(.rect(cornerRadius: 14, style: .continuous))
            } else {
                ActorAvatarView(actor: me, size: 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .frame(width: video == nil ? 150 : 200, height: video == nil ? 100 : 132)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            if isHandRaised { HandBadge(size: 10).padding(6) }
        }
        .speakingRing(isSpeaking, cornerRadius: 14)
        .accessibilityLabel(isMuted ? "You, muted" : "You")
    }
}

/// A round glass control with its name under it: white while it is on.
private struct CallControlButton: View {
    let symbol: String
    let title: String
    let help: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isActive ? .black : .white)
                    .frame(width: 62, height: 62)
                    .background {
                        if isActive { Circle().fill(.white) }
                    }
                    .glassEffect(isActive ? .identity : .regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            CallButtonTitle(title)
        }
    }
}

/// The name under a call button.
private struct CallButtonTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

/// While the call is minimized, or another conversation is open: who, how long, mute, and
/// the way back to the full call.
struct ReturnToCallPill: View {
    let call: CallController
    var onReturn: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReturn) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(call.participants.count == 1 ? call.participants[0].name : call.conversation.displayName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let since = call.answeredAt {
                        Text(since, style: .timer).monospacedDigit()
                    } else {
                        Text("Calling…")
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Back to the call")

            Button(action: call.toggleMute) {
                Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(call.isMuted ? 0.95 : 0.2), in: .circle)
                    .foregroundStyle(call.isMuted ? Color.green : .white)
            }
            .buttonStyle(.plain)
            .help(call.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(call.isMuted ? "Unmute" : "Mute")
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.green, in: .capsule)
    }
}

/// The call's "more" button: Live Captions, and which camera, microphone and speaker the call
/// uses — AirPods, a headset, the Mac's own.
private struct AudioDeviceMenu: View {
    /// Notes on the call so far; nil without captions to write them from.
    var onSummarize: (() -> Void)?
    let captions: LiveCaptions
    let devices: AudioDevices
    let cameras: [(id: String, name: String)]
    let cameraID: String?
    var onMicrophone: (AudioObjectID) -> Void
    var onSpeaker: (AudioObjectID) -> Void
    var onCamera: (String) -> Void

    var body: some View {
        VStack(spacing: 7) {
            menu
            CallButtonTitle("More")
        }
    }

    /// Built by AppKit when clicked: the stage redraws every second (the timer, who's
    /// talking), and a SwiftUI menu here was rebuilt each time, blinking its submenus.
    private var menu: some View {
        PopUpMenuButton {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("More — Live Captions, camera, microphone and speaker")
        .accessibilityLabel("More")
    }

    private var items: [PopUpMenuItem] {
        var items: [PopUpMenuItem] = []
        if let onSummarize {
            items.append(.action("Summarize Call So Far", systemImage: "apple.intelligence", perform: onSummarize))
        }
        items += captions.menuItems
        if cameras.count > 1 {
            items.append(.header("Camera"))
            let current = cameraID ?? cameras.first?.id
            for camera in cameras {
                items.append(.action(camera.name, isChecked: camera.id == current) { onCamera(camera.id) })
            }
        }
        items.append(.header("Microphone"))
        if devices.inputs.isEmpty {
            items.append(.action("None connected", isEnabled: false) {})
        }
        for device in devices.inputs {
            items.append(.action(device.name, isChecked: device.id == devices.defaultInput) { onMicrophone(device.id) })
        }
        items.append(.header("Speaker"))
        for device in devices.outputs {
            items.append(.action(device.name, isChecked: device.id == devices.defaultOutput) { onSpeaker(device.id) })
        }
        return items
    }
}

/// The ring around whoever is talking: it comes on with the first word and fades once they
/// stop, the way FaceTime lights up the tile of whoever has the floor. Reduce Motion keeps
/// the ring and leaves out the breath of scale.
struct SpeakingRing: ViewModifier {
    let isSpeaking: Bool
    /// The corner of the thing it goes around; nil for a round picture.
    var cornerRadius: CGFloat?
    var lineWidth: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay { ring.opacity(isSpeaking ? 1 : 0) }
            .shadow(color: .white.opacity(isSpeaking ? 0.3 : 0), radius: 12)
            .scaleEffect(isSpeaking && !reduceMotion ? 1.015 : 1)
            .animation(.smooth(duration: 0.22), value: isSpeaking)
    }

    @ViewBuilder private var ring: some View {
        if let cornerRadius {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white, lineWidth: lineWidth)
        } else {
            Circle().strokeBorder(.white, lineWidth: lineWidth)
        }
    }
}

extension View {
    /// Rings this while they are talking. See ``SpeakingRing``.
    func speakingRing(_ isSpeaking: Bool, cornerRadius: CGFloat? = nil, lineWidth: CGFloat = 3) -> some View {
        modifier(SpeakingRing(isSpeaking: isSpeaking, cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

/// Rings going out from a picture and fading, one after another — a call ringing. Still, with
/// Reduce Motion: a single faint ring.
private struct RingingRings: View {
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 2)
                .frame(width: diameter * 1.25, height: diameter * 1.25)
        } else {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (time / 2.4 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(.white.opacity(0.45 * (1 - phase)), lineWidth: 2)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(1 + 0.7 * phase)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// Your own tile, which can be picked up and put in any of seven places — the four corners and
/// the middle of the left, top and right edges; the middle of the bottom is the controls'. Let
/// go, it settles into the place nearest to where it was put down. The place is remembered for
/// the next call.
private struct MovableSelfTile: View {
    let me: MessageActor
    let isMuted: Bool
    var isSpeaking = false
    var isHandRaised = false
    let video: VideoTrack?

    enum Spot: String, CaseIterable {
        case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottomTrailing
    }

    @AppStorage("callSelfTileSpot") private var spotName = Spot.bottomTrailing.rawValue
    @State private var drag: CGSize = .zero
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Clear of the edges; at the top, clear of the minimize button and the name as well.
    private static let margin: CGFloat = 20
    private static let topInset: CGFloat = 140

    private var spot: Spot { Spot(rawValue: spotName) ?? .bottomTrailing }

    /// The tile's size, as ``SelfTile`` draws itself.
    private var tileSize: CGSize {
        video == nil ? CGSize(width: 150, height: 100) : CGSize(width: 200, height: 132)
    }

    var body: some View {
        GeometryReader { proxy in
            let here = center(of: spot, in: proxy.size)
            SelfTile(me: me, isMuted: isMuted, isSpeaking: isSpeaking, isHandRaised: isHandRaised, video: video)
                .scaleEffect(isDragging ? 1.05 : 1)
                .shadow(color: .black.opacity(isDragging ? 0.35 : 0.2), radius: isDragging ? 20 : 10, y: isDragging ? 10 : 4)
                .position(x: here.x + drag.width, y: here.y + drag.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            drag = clamped(value.translation, from: here, in: proxy.size)
                            if !isDragging {
                                withAnimation(.smooth(duration: 0.2)) { isDragging = true }
                            }
                        }
                        .onEnded { _ in
                            // Where it was let go: the nearest place takes it.
                            let now = CGPoint(x: here.x + drag.width, y: here.y + drag.height)
                            let nearest = Spot.allCases.min { lhs, rhs in
                                distance(center(of: lhs, in: proxy.size), now) < distance(center(of: rhs, in: proxy.size), now)
                            } ?? spot
                            withAnimation(reduceMotion ? .smooth(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)) {
                                spotName = nearest.rawValue
                                drag = .zero
                                isDragging = false
                            }
                        }
                )
                .animation(.smooth(duration: 0.25), value: tileSize)
        }
    }

    private func center(of spot: Spot, in size: CGSize) -> CGPoint {
        let half = CGSize(width: tileSize.width / 2, height: tileSize.height / 2)
        let left = Self.margin + half.width
        let right = size.width - Self.margin - half.width
        let top = Self.topInset + half.height
        let bottom = size.height - Self.margin - half.height
        let middleX = size.width / 2
        let middleY = (top + bottom) / 2
        switch spot {
        case .topLeading: return CGPoint(x: left, y: top)
        case .top: return CGPoint(x: middleX, y: top)
        case .topTrailing: return CGPoint(x: right, y: top)
        case .leading: return CGPoint(x: left, y: middleY)
        case .trailing: return CGPoint(x: right, y: middleY)
        case .bottomLeading: return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    /// A drag that keeps the whole tile inside the stage.
    private func clamped(_ translation: CGSize, from here: CGPoint, in size: CGSize) -> CGSize {
        let half = CGSize(width: tileSize.width / 2, height: tileSize.height / 2)
        let x = min(max(here.x + translation.width, half.width + 6), size.width - half.width - 6)
        let y = min(max(here.y + translation.height, half.height + 6), size.height - half.height - 6)
        return CGSize(width: x - here.x, height: y - here.y)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
