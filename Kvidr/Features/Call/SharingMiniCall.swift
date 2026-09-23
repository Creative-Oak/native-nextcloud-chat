import AppKit
import SwiftUI

/// While this Mac shares its screen, kvidr gets out of the way: its window goes to the Dock, and
/// a small call floats above everything instead — the other side's feed, your own, and the
/// controls — as Zoom does it. It doesn't take the focus from what's being presented, can be
/// dragged anywhere, and is left out of a shared display (see ``ScreenShare``).
@MainActor
final class SharingMiniCall {
    private var panel: NSPanel?
    private weak var mainWindow: NSWindow?

    /// Sharing began: the window to the Dock, and the mini call up.
    func start(call: CallController, me: MessageActor, avatarLoader: AvatarLoader?, onReturn: @escaping () -> Void, onLeave: @escaping () -> Void) {
        show(call: call, me: me, avatarLoader: avatarLoader, onReturn: onReturn, onLeave: onLeave)
        let window = NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        mainWindow = window
        window?.miniaturize(nil)
        // Back from the Dock is kvidr in front, even when the app never stopped being active.
        if let window {
            restoreObserver.map(NotificationCenter.default.removeObserver)
            restoreObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private var restoreObserver: (any NSObjectProtocol)?

    /// Floats the mini call, if it isn't already. kvidr in front hides it — see ``hide()``.
    func show(call: CallController, me: MessageActor, avatarLoader: AvatarLoader?, onReturn: @escaping () -> Void, onLeave: @escaping () -> Void) {
        guard panel == nil else { return }
        let content = MiniCallView(call: call, me: me, onReturn: onReturn, onLeave: onLeave, onResize: { [weak self] size in self?.fit(size) })
            .environment(\.avatarLoader, avatarLoader)
        let hosting = FirstClickHostingView(rootView: AnyView(content))
        // The panel's size is set here and in ``fit(_:)`` alone: left to itself the hosting view
        // would resize it too, keeping the bottom edge where it was rather than the top.
        hosting.sizingOptions = []
        // As big as what's in it, so the glass hugs it evenly on every side.
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// What's in it changed size — captions turned on or off: the window follows, its top edge
    /// staying where it is so it grows and shrinks downwards.
    private func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, panel.frame.size != size else { return }
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    /// kvidr came to the front while sharing: the call is in its window, so the mini call goes.
    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// The mini call away, and kvidr's window back.
    func close(restoringWindow: Bool = true) {
        panel?.orderOut(nil)
        panel = nil
        restoreObserver.map(NotificationCenter.default.removeObserver)
        restoreObserver = nil
        guard restoringWindow else { return }
        if let window = mainWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The mini call: the other side on top, you under, Live Captions when they're on, and the
/// call's controls — on the system's own glass, which follows the Mac's appearance settings
/// for it.
private struct MiniCallView: View {
    let call: CallController
    let me: MessageActor
    var onReturn: () -> Void
    var onLeave: () -> Void
    var onResize: (CGSize) -> Void

    private static let inset: CGFloat = 10
    private static let cornerRadius: CGFloat = 26

    var body: some View {
        VStack(spacing: 8) {
            other
            own
            if call.captions.isOn {
                CompactCaptionsView(captions: call.captions, width: Tile<EmptyView>.width, cornerRadius: Self.cornerRadius - Self.inset)
            }
            GlassEffectContainer(spacing: 8) {
                controls
            }
            .padding(.top, 2)
        }
        .padding(Self.inset)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        // Moved by dragging anywhere but a button — the pictures included. A borderless
        // panel's "movable by its background" doesn't reach through SwiftUI's content.
        .gesture(WindowDragGesture())
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onResize)
    }

    /// The person on the other end — or, in a group, whoever spoke last.
    private var shown: CallController.Participant? {
        call.participants.first { $0.id == call.recentSpeakerID } ?? call.participants.first
    }

    private var other: some View {
        Tile(cornerRadius: Self.cornerRadius - Self.inset, isSpeaking: shown?.isSpeaking ?? false) {
            if let person = shown {
                if person.isVideoOn, let video = person.video {
                    VideoView(video: video)
                } else {
                    ActorAvatarView(actor: person.actor, size: 64)
                }
            } else {
                AvatarView(conversation: call.conversation, size: 64)
            }
        } caption: {
            (call.participants.contains(where: \.isHandRaised) ? "✋ " : "")
                + (call.participants.count > 1
                    ? "\(shown?.name ?? call.participants[0].name) +\(call.participants.count - 1)"
                    : call.participants.first?.name ?? call.conversation.displayName)
        }
    }

    private var own: some View {
        Tile(cornerRadius: Self.cornerRadius - Self.inset, isSpeaking: call.isSpeaking) {
            if call.isCameraOn, let video = call.localVideo {
                VideoView(video: video, isMirrored: true)
            } else {
                ActorAvatarView(actor: me, size: 64)
            }
        } caption: {
            call.isMuted ? "You · muted" : "You"
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            MiniButton(symbol: call.isMuted ? "mic.slash.fill" : "mic.fill", help: call.isMuted ? "Unmute" : "Mute", isActive: call.isMuted, action: call.toggleMute)
            MiniButton(symbol: call.isCameraOn ? "video.fill" : "video.slash.fill", help: call.isCameraOn ? "Turn camera off" : "Turn camera on", isActive: call.isCameraOn, action: call.toggleCamera)
            MiniButton(symbol: "rectangle.slash", help: "Stop sharing your screen", tint: .green, action: call.stopSharingScreen)
            MiniButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Back to kvidr", action: onReturn)
            MiniButton(symbol: "phone.down.fill", help: "End the call", tint: .red, action: onLeave)
        }
    }
}

private struct Tile<Content: View>: View {
    static var width: CGFloat { 232 }

    let cornerRadius: CGFloat
    var isSpeaking = false
    @ViewBuilder var content: Content
    var caption: () -> String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black.opacity(0.25))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            Text(caption())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .padding(8)
        }
        .frame(width: Self.width, height: 130)
        .speakingRing(isSpeaking, cornerRadius: cornerRadius, lineWidth: 2.5)
    }
}

/// A round button: clear glass when idle; solid white while on, and solid green and red for
/// stop and end — colours, as in the call's own bar, that glass would wash out.
private struct MiniButton: View {
    let symbol: String
    let help: String
    var isActive = false
    var tint: Color?
    let action: () -> Void

    private var fill: Color? { tint ?? (isActive ? .white : nil) }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isActive && tint == nil ? Color.black : Color.white)
                .frame(width: 40, height: 40)
                .background {
                    if let fill { Circle().fill(fill) }
                }
        }
        .buttonStyle(.plain)
        .glassEffect(fill == nil ? .regular.interactive() : .identity, in: .circle)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A click on the panel presses the button under it — the panel never becomes the active
/// window, so without this the first click would only be taken as reaching for it.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
