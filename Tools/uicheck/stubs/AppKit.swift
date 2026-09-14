// A stand-in for AppKit: the types this app touches, with faithful names and labels.
@_exported import Foundation
import UniformTypeIdentifiers

public typealias NSSize = CGSize
public typealias NSPoint = CGPoint
public typealias NSRect = CGRect

/// Objective-C interop doesn't exist off Apple platforms, so `Selector` is modelled as a
/// plain value and the check harness rewrites `#selector(...)` into `Selector("...")`
/// before type-checking. Everything else about the file being checked is unchanged.
public struct Selector: Equatable, Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

@MainActor open class NSResponder: NSObject {
    public override init() { super.init() }
    open func insertNewline(_ sender: Any?) {}
    open func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
    open func insertTab(_ sender: Any?) {}
    open func cancelOperation(_ sender: Any?) {}
    open func moveUp(_ sender: Any?) {}
    open func moveDown(_ sender: Any?) {}
}

@MainActor open class NSView: NSResponder {
    public init(frame: NSRect) { super.init() }
    open var window: NSWindow? { nil }
    open var frame: NSRect = .zero
    open var bounds: NSRect { .zero }
    open var superview: NSView? { nil }
    open var fittingSize: NSSize { .zero }
    open func viewDidMoveToWindow() {}
    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint { point }
    open func hitTest(_ point: NSPoint) -> NSView? { nil }
    open func rightMouseDown(with event: NSEvent) {}
    open func mouseDown(with event: NSEvent) {}
}

@MainActor open class NSWindow: NSResponder {
    public static var allowsAutomaticWindowTabbing: Bool = true
    open var firstResponder: NSResponder? { nil }
    open var frameAutosaveName: String = ""
    open var frame: NSRect { .zero }
    open var isRestorable: Bool = true
    open var isVisible: Bool { true }
    open var tabbingMode: TabbingMode = .automatic
    public enum TabbingMode: Sendable { case automatic, preferred, disallowed }
    open var titleVisibility: TitleVisibility = .visible
    public enum TitleVisibility: Sendable { case visible, hidden }
    open var titlebarSeparatorStyle: TitlebarSeparatorStyle = .automatic
    public enum TitlebarSeparatorStyle: Sendable { case automatic, none, line, shadow }
    @discardableResult open func setFrameAutosaveName(_ name: String) -> Bool { true }
    open func setFrame(_ frameRect: NSRect, display flag: Bool) {}
    open func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
    open func makeKeyAndOrderFront(_ sender: Any?) {}
    public static let didBecomeKeyNotification = Notification.Name("NSWindowDidBecomeKey")
    public static let didResignKeyNotification = Notification.Name("NSWindowDidResignKey")
}

@MainActor public final class NSApplication {
    public static let shared = NSApplication()
    public var windows: [NSWindow] { [] }
    public var currentEvent: NSEvent? { nil }
    public let dockTile = NSDockTile()
    public func activate(ignoringOtherApps: Bool) {}
    public func activate() {}
    public func orderFrontCharacterPalette(_ sender: Any?) {}
    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActive")
    public static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActive")
    public enum TerminateReply: Sendable { case terminateNow, terminateCancel, terminateLater }
    public func reply(toApplicationShouldTerminate: Bool) {}
}

@MainActor public final class NSDockTile {
    public var badgeLabel: String?
}

@MainActor public protocol NSApplicationDelegate: NSObjectProtocol {
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationWillTerminate(_ notification: Notification)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
}

extension NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {}
    public func applicationWillTerminate(_ notification: Notification) {}
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

@MainActor open class NSImage: NSObject {
    public init?(systemSymbolName: String, accessibilityDescription: String?) { super.init() }
    public init?(data: Data) { super.init() }
    public init(size: NSSize) { super.init() }
    open var size: NSSize = .zero
    open var tiffRepresentation: Data? { nil }
}

@MainActor open class NSBitmapImageRep: NSObject {
    public init?(data: Data) { super.init() }
    public enum FileType: Sendable { case png, jpeg, tiff, gif, bmp }
    public enum PropertyKey: Hashable, Sendable { case compressionFactor }
    open func representation(using type: FileType, properties: [PropertyKey: Any]) -> Data? { nil }
}

public struct NSColor: Sendable {
    public static let textBackgroundColor = NSColor()
    public static let windowBackgroundColor = NSColor()
    public static let separatorColor = NSColor()
    public static let controlBackgroundColor = NSColor()
    public static let labelColor = NSColor()
    public static let secondaryLabelColor = NSColor()
    public static let selectedContentBackgroundColor = NSColor()
    public static let unemphasizedSelectedContentBackgroundColor = NSColor()
}

@MainActor public final class NSPasteboard {
    public static let general = NSPasteboard()
    public struct PasteboardType: Hashable, Sendable {
        public static let string = PasteboardType()
        public static let fileURL = PasteboardType()
        public static let png = PasteboardType()
        public static let tiff = PasteboardType()
    }
    @discardableResult public func clearContents() -> Int { 0 }
    @discardableResult public func setString(_ string: String, forType type: PasteboardType) -> Bool { true }
    public func string(forType type: PasteboardType) -> String? { nil }
    public func data(forType type: PasteboardType) -> Data? { nil }
    public func canReadObject(forClasses classes: [AnyClass], options: [AnyHashable: Any]?) -> Bool { false }
}

public final class NSItemProvider: NSObject, @unchecked Sendable {
    public func canLoadObject<T: AnyObject>(ofClass aClass: T.Type) -> Bool { false }
    public func loadObject<T: AnyObject>(ofClass aClass: T.Type, completionHandler: @escaping (T?, Error?) -> Void) {}
}

@MainActor public final class NSWorkspace {
    public static let shared = NSWorkspace()
    @discardableResult public func open(_ url: URL) -> Bool { true }
    public func activateFileViewerSelecting(_ urls: [URL]) {}
    public func selectFile(_ path: String?, inFileViewerRootedAtPath root: String) -> Bool { true }
}

@MainActor open class NSSavePanel: NSObject {
    public override init() { super.init() }
    open var nameFieldStringValue: String = ""
    open var canCreateDirectories: Bool = true
    open var message: String = ""
    open var prompt: String = ""
    open var url: URL? { nil }
    open var directoryURL: URL?
    open var allowedContentTypes: [UTType] = []
    open func runModal() -> ModalResponse { .OK }
    public struct ModalResponse: Equatable, Sendable {
        public static let OK = ModalResponse()
        public static let cancel = ModalResponse()
    }
}

@MainActor public final class NSOpenPanel: NSSavePanel {
    public var allowsMultipleSelection: Bool = false
    public var canChooseDirectories: Bool = false
    public var canChooseFiles: Bool = true
    public var urls: [URL] { [] }
}

@MainActor open class NSScrollView: NSView {
    open var documentView: NSView?
    open var drawsBackground: Bool = true
    open var hasVerticalScroller: Bool = false
    open var autohidesScrollers: Bool = false
    open var verticalScrollElasticity: Elasticity = .automatic
    public enum Elasticity: Sendable { case automatic, none, allowed }
}

@MainActor open class NSTextContainer: NSObject {
    open var widthTracksTextView: Bool = true
    open var lineFragmentPadding: CGFloat = 5
}

@MainActor open class NSLayoutManager: NSObject {
    open func ensureLayout(for container: NSTextContainer) {}
    open func usedRect(for container: NSTextContainer) -> NSRect { .zero }
}

@MainActor open class NSTextView: NSView {
    public static func scrollableTextView() -> NSScrollView { NSScrollView(frame: .zero) }
    open weak var delegate: (any NSTextViewDelegate)?
    open var string: String = ""
    open var isRichText: Bool = true
    open var isEditable: Bool = true
    open var isSelectable: Bool = true
    open var allowsUndo: Bool = false
    open var font: NSFont?
    open var drawsBackground: Bool = true
    open var textContainerInset: NSSize = .zero
    open var isAutomaticQuoteSubstitutionEnabled: Bool = true
    open var isAutomaticDashSubstitutionEnabled: Bool = true
    open var isAutomaticLinkDetectionEnabled: Bool = true
    open var isContinuousSpellCheckingEnabled: Bool = false
    open var isGrammarCheckingEnabled: Bool = false
    open var textContainer: NSTextContainer? { NSTextContainer() }
    open var layoutManager: NSLayoutManager? { NSLayoutManager() }
    open var enclosingScrollView: NSScrollView? { nil }
    open func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    open func setSelectedRange(_ range: NSRange) {}
}

@MainActor public protocol NSTextViewDelegate: NSObjectProtocol {
    func textDidChange(_ notification: Notification)
    func textDidBeginEditing(_ notification: Notification)
    func textDidEndEditing(_ notification: Notification)
    func textViewDidChangeSelection(_ notification: Notification)
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool
}

extension NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {}
    public func textDidBeginEditing(_ notification: Notification) {}
    public func textDidEndEditing(_ notification: Notification) {}
    public func textViewDidChangeSelection(_ notification: Notification) {}
    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { false }
}

public struct NSFont: Sendable {
    public enum TextStyle: Sendable { case body, callout, caption1, headline, title1 }
    public static func preferredFont(forTextStyle style: TextStyle) -> NSFont { NSFont() }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont() }
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont() }
    public struct Weight: Sendable { public static let regular = Weight(); public static let medium = Weight() }
}

@MainActor public let NSApp = NSApplication.shared

@MainActor open class NSEvent: NSObject {
    public enum EventType: Sendable { case leftMouseDown, rightMouseDown, mouseMoved }
    public struct ModifierFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let control = ModifierFlags(rawValue: 1 << 18)
    }
    open var type: EventType { .leftMouseDown }
    open var modifierFlags: ModifierFlags { [] }
}



@MainActor open class NSMenuItem: NSObject {
    public init(title: String, action: Selector?, keyEquivalent: String) { super.init() }
    public override init() { super.init() }
    public required init(coder: NSCoder) { super.init() }
    open var target: AnyObject?
    open var image: NSImage?
    open var view: NSView?
    public static func separator() -> NSMenuItem { NSMenuItem() }
}

@MainActor open class NSMenu: NSObject {
    public override init() { super.init() }
    open var autoenablesItems = true
    open func addItem(_ item: NSMenuItem) {}
    open func cancelTracking() {}
    public static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {}
}
