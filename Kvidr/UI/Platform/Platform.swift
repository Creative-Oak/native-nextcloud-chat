import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few system services every screen reaches for, spelled once for both platforms.
///
/// kvidr is one SwiftUI app built for the Mac and for iPhone and iPad. Almost all of it is
/// shared; what differs is the handful of framework types below, and the views that are
/// genuinely platform-shaped (the composer's text view, window chrome), which carry their own
/// `#if os(macOS)` branches.
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage image: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension PlatformImage {
    /// PNG bytes, for pasting an image into the composer and saving one to disk.
    var pngData: Data? {
        #if os(macOS)
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return pngData()
        #endif
    }
}

@MainActor
enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

@MainActor
enum Platform {
    /// Opens a URL with whatever the system has for it — the browser, Mail, Maps.
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Posted when the app comes to the front: the Mac's "became active", iOS's "entered the
    /// foreground and is active".
    static var didBecomeActive: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    static var didResignActive: Notification.Name {
        #if os(macOS)
        NSApplication.didResignActiveNotification
        #else
        UIApplication.willResignActiveNotification
        #endif
    }

    static var isActive: Bool {
        #if os(macOS)
        NSApp.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    /// Whether this is an iPhone: the one place the app is always a single column.
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

#if os(macOS)
typealias PlatformFont = NSFont
#else
typealias PlatformFont = UIFont
#endif

extension View {
    /// Escape dismisses. The Mac's exit command also covers ⌘-period; on iPad it is the
    /// hardware keyboard's Escape key, and on iPhone the gesture that goes with the view.
    func onEscape(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) {
            action()
            return .handled
        }
        #endif
    }

    /// The pointing-hand cursor over something clickable. iPad's pointer finds buttons on
    /// its own.
    func linkPointer() -> some View {
        #if os(macOS)
        pointerStyle(.link)
        #else
        self
        #endif
    }
}

/// The system colours the app draws with, by the Mac's names.
extension Color {
    /// Behind text you read: the transcript, the inspector.
    static var textBackground: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var separatorLine: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    /// A selected row's fill. On iOS that is the tint, as in a selected sidebar row.
    static var selectedContentBackground: Color {
        #if os(macOS)
        Color(nsColor: .selectedContentBackgroundColor)
        #else
        Color(uiColor: .tintColor)
        #endif
    }
}

#if os(iOS)
/// The Mac's borderless link button — tinted text that is a button — which iOS lacks.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var link: LinkButtonStyle { LinkButtonStyle() }
}
#endif

extension Font {
    /// The Mac's small print, a step up on iPhone and iPad — where 12pt, fine on a desk, is
    /// squinting at arm's length. Bars and small rows use it; body text is the system's.
    static func scaled(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if os(iOS)
        .system(size: size + 3, weight: weight)
        #else
        .system(size: size, weight: weight)
        #endif
    }
}

extension View {
    /// The Mac's typed-in date field; iOS's compact picker in its place.
    func fieldDatePicker() -> some View {
        #if os(macOS)
        datePickerStyle(.field)
        #else
        datePickerStyle(.compact)
        #endif
    }
}
