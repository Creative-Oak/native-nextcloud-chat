import AppKit
import SwiftUI

/// Over a conversation opened with a lot unread: the offer of a summary, then the summary as
/// it is written. One line until there is something to read, like the out-of-office bar.
struct SummaryBar: View {
    let summary: UnreadSummary
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple.gradient)

                Text(headline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer(minLength: 6)

                switch summary.state {
                case .offered:
                    Button("Summarize") { summary.write() }
                        .buttonStyle(.link)
                        .fixedSize()
                case .writing:
                    ProgressView().controlSize(.mini)
                case .written, .failed:
                    EmptyView()
                }

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide")
                .accessibilityLabel("Hide the summary")
            }

            if let body = bodyText {
                ScrollView {
                    Text(body)
                        .foregroundStyle(isFailure ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 17)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .glass(.panel, cornerRadius: 10)
        // Read, it goes when you click anywhere else — the click still does what it was for.
        .background {
            if isFinished { ClickOutsideWatcher(onClickOutside: onDismiss) }
        }
        .animation(.smooth(duration: 0.2), value: summary.state)
    }

    private var isFinished: Bool {
        switch summary.state {
        case .written, .failed: true
        case .offered, .writing: false
        }
    }

    private var headline: String {
        switch summary.state {
        case .offered:
            "\(summary.unreadCount) unread messages"
        case .writing:
            "Summarizing…"
        case .written, .failed:
            if let subject = summary.subject {
                "Summary of \(subject)"
            } else if summary.isRecent {
                "Summary of the latest \(summary.coveredCount) messages"
            } else if summary.coveredCount > 0 && summary.coveredCount < summary.unreadCount {
                "Summary of the latest \(summary.coveredCount) of \(summary.unreadCount) messages"
            } else {
                "Summary of \(summary.unreadCount) unread messages"
            }
        }
    }

    private var bodyText: String? {
        switch summary.state {
        case .offered: nil
        case .writing(let text): text.isEmpty ? nil : text
        case .written(let text): text
        case .failed(let reason): reason
        }
    }

    private var isFailure: Bool {
        if case .failed = summary.state { return true }
        return false
    }
}

/// Calls back when the mouse goes down in this window outside the view it sits behind.
/// Watches without taking the click, so whatever was clicked still gets it.
private struct ClickOutsideWatcher: NSViewRepresentable {
    var onClickOutside: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onClickOutside = onClickOutside
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stopWatching()
    }

    final class WatcherView: NSView {
        var onClickOutside: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) {
                    // After this click has been handled, not in the middle of it.
                    DispatchQueue.main.async { self.onClickOutside?() }
                }
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
