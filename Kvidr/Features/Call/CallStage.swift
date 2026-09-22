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
    var onDismiss: () -> Void
    /// Shrinks the call to a pill, back to the messages.
    var onMinimize: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            backdrop

            switch call.phase {
            case .ended(let reason):
                ended(reason: reason)
            case .joining, .inCall:
                stage
            }
        }
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

            Group {
                if call.participants.isEmpty {
                    waiting
                } else if soloVideo != nil {
                    // Their video is the backdrop, and their name is already at the top.
                    Color.clear
                } else if let only = soloParticipant {
                    // No video: their picture, large, as the iPhone shows whoever you're talking to.
                    ZStack(alignment: .bottomTrailing) {
                        ActorAvatarView(actor: only.actor, size: 200)
                            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                            .opacity(only.isConnected ? 1 : 0.6)
                        if !only.isAudioOn {
                            Image(systemName: "mic.slash.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular, in: .circle)
                        }
                    }
                } else {
                    tiles
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

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
        .overlay(alignment: .bottomTrailing) {
            SelfTile(me: me, isMuted: call.isMuted, video: call.isCameraOn ? call.localVideo : nil)
                .padding(.trailing, 20)
                .padding(.bottom, 20)
        }
    }

    /// The iPhone's order: how long, small, over who — large.
    private var header: some View {
        VStack(spacing: 4) {
            Group {
                if let since = call.connectedAt, !call.participants.isEmpty {
                    Text(since, style: .timer).monospacedDigit()
                } else if call.phase == .joining {
                    Text("Connecting…")
                } else {
                    Text("Calling…")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 10) {
                Text(soloParticipant?.name ?? call.conversation.displayName)
                    .font(.system(size: 40, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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

    private var waiting: some View {
        AvatarView(conversation: call.conversation, size: 200)
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    private var tiles: some View {
        let columns = [GridItem(.adaptive(minimum: call.participants.count == 1 ? 320 : 220), spacing: 14)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(call.participants) { participant in
                    ParticipantTile(participant: participant, isLarge: call.participants.count == 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.center)
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

            AudioDeviceMenu(
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
                .help("Leave the call")
                .accessibilityLabel("Leave the call")
                CallButtonTitle("End")
            }
        }
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
        }
    }
}

/// Someone else in the call: their picture large on a dark card, their name in the corner,
/// FaceTime's tile without the camera.
private struct ParticipantTile: View {
    let participant: CallController.Participant
    let isLarge: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
            if participant.isVideoOn, let video = participant.video {
                VideoView(video: video)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
            } else {
                ActorAvatarView(actor: actor, size: isLarge ? 150 : 96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .aspectRatio(isLarge ? 4 / 3 : 1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participant.isConnected ? participant.name : "\(participant.name), connecting")
    }

    private var actor: MessageActor {
        MessageActor(type: participant.actorType ?? "users", id: participant.actorID ?? participant.userID ?? "", displayName: participant.name)
    }
}

/// You, small in the corner — where FaceTime puts your camera.
private struct SelfTile: View {
    let me: MessageActor
    let isMuted: Bool
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
                    if let since = call.connectedAt {
                        Text(since, style: .timer).monospacedDigit()
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

/// The call's "more" button: which camera, microphone and speaker it uses — AirPods, a
/// headset, the Mac's own — and, later, what else a call can do.
private struct AudioDeviceMenu: View {
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

    private var menu: some View {
        Menu {
            if cameras.count > 1 {
                Section("Camera") {
                    ForEach(cameras, id: \.id) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { camera.id == (cameraID ?? cameras.first?.id) },
                            set: { _ in onCamera(camera.id) }
                        ))
                    }
                }
            }
            Section("Microphone") {
                if devices.inputs.isEmpty {
                    Text("None connected")
                }
                ForEach(devices.inputs) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { device.id == devices.defaultInput },
                        set: { _ in onMicrophone(device.id) }
                    ))
                }
            }
            Section("Speaker") {
                ForEach(devices.outputs) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { device.id == devices.defaultOutput },
                        set: { _ in onSpeaker(device.id) }
                    ))
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More — camera, microphone and speaker")
        .accessibilityLabel("More")
    }
}
