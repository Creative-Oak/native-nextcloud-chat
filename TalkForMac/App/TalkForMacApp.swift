import AppKit
import SwiftUI

@main
struct TalkForMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(\.preferences, app.dependencies.preferences)
                .environment(\.avatarLoader, app.avatarLoader)
                .onAppear { appDelegate.app = app }
                .frame(minWidth: 720, minHeight: 460)
        }
        // Restores size and position across launches, which macOS handles for us as long as
        // the scene has a stable identity.
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands { TalkCommands() }

        Settings {
            SettingsView()
                .environment(app)
                .environment(\.preferences, app.dependencies.preferences)
        }
    }
}

/// AppKit behaviour SwiftUI doesn't cover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    /// A messaging app keeps running when you close its window — that is what makes it able
    /// to notice new messages at all. Clicking the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Re-show the existing window rather than opening a second one.
            for window in sender.windows where !window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Quitting with a half-typed message must not lose it.
    ///
    /// Draft saves are debounced while typing, so on quit there can be up to a few hundred
    /// milliseconds of unwritten text. `.terminateLater` waits for the write — a local
    /// store write, so the wait is imperceptible — rather than racing the process exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let chat = app?.chat else { return .terminateNow }
        Task {
            await chat.flushDraft()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
