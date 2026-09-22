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

    /// The conversation's picture, blown up and blurred into the dark — where FaceTime shows
    /// the other person's camera.
    private var backdrop: some View {
        ZStack {
            Color(white: 0.07)
            AvatarView(conversation: call.conversation, size: 520)
                .blur(radius: 90)
                .opacity(0.45)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }

    private var stage: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 52)
                .padding(.horizontal, 24)

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
        .overlay(alignment: .bottomTrailing) {
            SelfTile(me: me, isMuted: call.isMuted)
                .padding(.trailing, 20)
                .padding(.bottom, 20)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(call.conversation.displayName)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Group {
                if let since = call.connectedAt {
                    Text(since, style: .timer).monospacedDigit()
                } else {
                    Text("Connecting…")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            AvatarView(conversation: call.conversation, size: 120)
            Text(call.phase == .joining ? "Calling…" : "Waiting for others to join…")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
        }
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

    private var controls: some View {
        HStack(spacing: 14) {
            CallControlButton(
                symbol: call.isMuted ? "mic.slash.fill" : "mic.fill",
                label: call.isMuted ? "Unmute" : "Mute",
                isOn: !call.isMuted,
                action: call.toggleMute
            )
            .keyboardShortcut("m", modifiers: [.command, .shift])

            AudioDeviceMenu(devices: call.audioDevices, onMicrophone: call.useMicrophone, onSpeaker: call.useSpeaker)

            CallControlButton(symbol: "video.slash.fill", label: "Camera comes in the next step", isOn: false, action: {})
                .disabled(true)

            Button(action: onLeave) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Leave the call")
            .accessibilityLabel("Leave the call")
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
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
            ActorAvatarView(actor: actor, size: isLarge ? 150 : 96)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(participant.isConnected ? 1 : 0.55)
            HStack(spacing: 6) {
                Text(participant.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !participant.isConnected {
                    ProgressView().controlSize(.mini)
                }
            }
            .foregroundStyle(.white)
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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.1))
            ActorAvatarView(actor: me, size: 54)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .frame(width: 150, height: 100)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .accessibilityLabel(isMuted ? "You, muted" : "You")
    }
}

/// A round control on the call's glass bar: filled when on, dim when off.
private struct CallControlButton: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? .black : .white)
                .frame(width: 52, height: 52)
                .background(isOn ? Color.white : Color.white.opacity(0.18), in: .circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// While the call goes on and another conversation is open: the way back to it.
struct ReturnToCallPill: View {
    let call: CallController
    var onReturn: () -> Void

    var body: some View {
        Button(action: onReturn) {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(call.conversation.displayName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let since = call.connectedAt {
                    Text(since, style: .timer).monospacedDigit()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.green, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Back to the call")
    }
}

/// Which microphone and speaker the call uses — AirPods, a headset, the Mac's own. A glass
/// button on the call's bar like the others, with the devices in its menu.
private struct AudioDeviceMenu: View {
    let devices: AudioDevices
    var onMicrophone: (AudioObjectID) -> Void
    var onSpeaker: (AudioObjectID) -> Void

    var body: some View {
        Menu {
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
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.18), in: .circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone and speaker")
        .accessibilityLabel("Microphone and speaker")
    }

    /// AirPods when they are what's in use, a speaker otherwise.
    private var symbol: String {
        let name = devices.outputs.first { $0.id == devices.defaultOutput }?.name.lowercased() ?? ""
        return name.contains("airpods") ? "airpods" : "speaker.wave.2.fill"
    }
}
