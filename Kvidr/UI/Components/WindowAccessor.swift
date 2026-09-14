import AppKit
import SwiftUI

/// Gives SwiftUI's window a frame autosave name, so macOS restores its size and position,
/// and sets the two title bar properties SwiftUI has no modifier for.
///
/// SwiftUI usually manages the frame for a `WindowGroup`, but naming it explicitly makes
/// it deterministic — and it's the difference between "the app remembers where I put it"
/// and "the app opens in the middle of the screen every time".
///
/// The configuration happens the moment this view joins the window, which is before the
/// window is first drawn. Deferring it to the next run loop turn — the usual
/// `DispatchQueue.main.async` — meant the window came up at its default size with its
/// title showing, then jumped to the saved frame and lost the title a frame later.
struct WindowConfigurator: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> ConfiguringView {
        let view = ConfiguringView(frame: .zero)
        view.autosaveName = autosaveName
        return view
    }

    func updateNSView(_ view: ConfiguringView, context: Context) {
        view.autosaveName = autosaveName
        view.configureWindow()
    }

    final class ConfiguringView: NSView {
        var autosaveName = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window, window.frameAutosaveName != autosaveName else { return }
            window.isRestorable = true
            window.setFrameAutosaveName(autosaveName)
            // Nothing in this app benefits from tabs, and they complicate ⌘W.
            window.tabbingMode = .disallowed
            // The conversation header already says who you are talking to, in the middle
            // of the window where Messages puts it. Leaving the title in the title bar as
            // well says it twice and costs a whole row of height. `window.title` is
            // untouched, so Mission Control and the Window menu still know what this
            // window is — SwiftUI's `.toolbar(removing: .title)` does not reach this and
            // has no effect.
            window.titleVisibility = .hidden
            // No hairline under the toolbar. Messages has no line there either; the
            // transcript's edge fade is the boundary.
            window.titlebarSeparatorStyle = .none
        }
    }
}

extension View {
    /// Remembers this window's size and position across launches.
    func remembersWindowFrame(named name: String) -> some View {
        background {
            WindowConfigurator(autosaveName: name)
                .frame(width: 0, height: 0)
        }
    }
}
