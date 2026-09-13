import AppKit
import SwiftUI

/// Gives SwiftUI's window a frame autosave name, so macOS restores its size and position.
///
/// SwiftUI usually manages this for a `WindowGroup`, but naming the frame explicitly makes
/// it deterministic — and it's the difference between "the app remembers where I put it"
/// and "the app opens in the middle of the screen every time".
struct WindowConfigurator: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window, window.frameAutosaveName != autosaveName else { return }
        window.isRestorable = true
        window.setFrameAutosaveName(autosaveName)
        // Nothing in this app benefits from tabs, and they complicate ⌘W.
        window.tabbingMode = .disallowed
    }
}

extension View {
    /// Remembers this window's size and position across launches.
    func remembersWindowFrame(named name: String) -> some View {
        background(WindowConfigurator(autosaveName: name).frame(width: 0, height: 0))
    }
}
