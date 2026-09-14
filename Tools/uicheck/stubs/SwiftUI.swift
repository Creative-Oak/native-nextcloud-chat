// A stand-in for SwiftUI, used only to type-check the app where there is no macOS SDK.
//
// This is not SwiftUI. It is a declaration of the API surface this app uses, deliberately
// permissive about return types (most modifiers return an opaque view) and deliberately
// faithful about *names, argument labels and actor isolation* — because those are what
// break a first build.
//
// If this file is missing something, the fix is to add it here. It is never a reason to
// change the app.
import AppKit
import Combine
@_exported import Foundation
@_exported import Observation

// MARK: - Core protocols

// `Body` is unconstrained on purpose: with a `@ViewBuilder` requirement, a `Never` body
// (which is how real SwiftUI marks a primitive view) can't be expressed in a stub, so every
// stub view simply reports `StubView` and nothing ever calls it.
@MainActor public protocol View {
    associatedtype Body
    @ViewBuilder @MainActor var body: Body { get }
}

public struct StubView: View {
    public init() {}
    public var body: StubView { self }
}

public struct EmptyView: View {
    public init() {}
    public var body: StubView { StubView() }
}

public struct AnyView: View {
    public init(_ view: some View) {}
    public var body: StubView { StubView() }
}

/// `buildOptional` is the one builder method whose generic parameter has to show up in the
/// return type: an `if` with no `else` passes `nil`, so there is nothing in the argument
/// position to infer `C` from.
public struct OptionalContent<C: View>: View {
    public init() {}
    public var body: StubView { StubView() }
}

/// Every branch collapses to ``StubView``.
///
/// Real SwiftUI threads the branch types through `_ConditionalContent`, but reproducing that
/// here builds a deeply nested generic type for every `if`/`switch` in a body — which both
/// slows type-checking to a crawl and, on Linux, crashes the result-builder transform
/// coercing an opaque `some View` onto the nested tree. Collapsing costs nothing: each
/// branch expression is still fully type-checked as a `View` before it is erased.
@resultBuilder public enum ViewBuilder {
    @MainActor public static func buildBlock() -> EmptyView { EmptyView() }
    @MainActor public static func buildBlock<C: View>(_ content: C) -> C { content }
    @MainActor public static func buildPartialBlock<C: View>(first: C) -> C { first }
    @MainActor public static func buildPartialBlock<A: View, N: View>(accumulated: A, next: N) -> StubView { StubView() }
    @MainActor public static func buildOptional<C: View>(_ content: C?) -> OptionalContent<C> { OptionalContent() }
    @MainActor public static func buildEither<C: View>(first: C) -> StubView { StubView() }
    @MainActor public static func buildEither<C: View>(second: C) -> StubView { StubView() }
    @MainActor public static func buildArray<C: View>(_ components: [C]) -> StubView { StubView() }
    @MainActor public static func buildLimitedAvailability<C: View>(_ content: C) -> StubView { StubView() }
    @MainActor public static func buildExpression<C: View>(_ expression: C) -> C { expression }
}

// MARK: - Property wrappers

@propertyWrapper public struct State<Value> {
    private final class Box: @unchecked Sendable { var value: Value; init(_ value: Value) { self.value = value } }
    private let box: Box
    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public init(initialValue: Value) { box = Box(initialValue) }
    // Nonmutating, exactly like the real one: assigning from inside `body` must work.
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

@dynamicMemberLookup @propertyWrapper public struct Binding<Value> {
    private let getter: () -> Value
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { getter = get }
    public var wrappedValue: Value {
        get { getter() }
        nonmutating set {}
    }
    public var projectedValue: Binding<Value> { self }
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> {
        let value = wrappedValue[keyPath: keyPath]
        return Binding<Subject>(get: { value }, set: { _ in })
    }
}

@dynamicMemberLookup @propertyWrapper public struct Bindable<Value: AnyObject> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(_ value: Value) { self.wrappedValue = value }
    public var projectedValue: Bindable<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>) -> Binding<Subject> {
        let value = wrappedValue[keyPath: keyPath]
        return Binding<Subject>(get: { value }, set: { _ in })
    }
}

@propertyWrapper public struct Environment<Value> {
    private let resolve: () -> Value
    public var wrappedValue: Value { resolve() }
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        resolve = { EnvironmentValues()[keyPath: keyPath] }
    }
    public init(_ type: Value.Type) where Value: AnyObject {
        resolve = { fatalError("the stub never resolves an environment object") }
    }
}

@propertyWrapper public struct FocusState<Value: Hashable> {
    private final class Box: @unchecked Sendable { var value: Value; init(_ value: Value) { self.value = value } }
    private let box: Box
    public init() where Value == Bool { box = Box(false) }
    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: FocusStateBinding<Value> { FocusStateBinding(value: box.value) }
}

public struct FocusStateBinding<Value: Hashable> {
    public var value: Value
    public var wrappedValue: Value {
        get { value }
        nonmutating set {}
    }
}

extension FocusState {
    public typealias Binding = FocusStateBinding<Value>
}

@propertyWrapper public struct FocusedValue<Value> {
    public var wrappedValue: Value?
    public init(_ keyPath: KeyPath<FocusedValues, Value?>) { wrappedValue = nil }
}

@propertyWrapper public struct Namespace {
    public struct ID: Hashable, Sendable {}
    public var wrappedValue: ID { ID() }
    public init() {}
}

@propertyWrapper public struct ScaledMetric<Value: BinaryFloatingPoint> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

// MARK: - Environment and focused values

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    public init() {}
    private var storage: [ObjectIdentifier: Any] = [:]

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { (storage[ObjectIdentifier(key)] as? K.Value) ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }

    public var colorScheme: ColorScheme { .light }
    public var accessibilityReduceMotion: Bool { false }
    public var dismiss: DismissAction { DismissAction() }
    public var openWindow: OpenWindowAction { OpenWindowAction() }
    public var openURL: OpenURLAction { OpenURLAction() }
    public var controlActiveState: ControlActiveState { .key }
    public var isEnabled: Bool { true }
    public var displayScale: CGFloat { 2 }
}

public struct DismissAction {
    public func callAsFunction() {}
}

public struct OpenWindowAction {
    public func callAsFunction(id: String) {}
    public func callAsFunction<V: Hashable>(id: String, value: V) {}
}

public struct OpenURLAction {
    public func callAsFunction(_ url: URL) {}
}

public enum ControlActiveState: Sendable { case key, active, inactive }
public enum ColorScheme: Sendable { case light, dark }

public protocol FocusedValueKey {
    associatedtype Value
}

public struct FocusedValues {
    public init() {}
    private var storage: [ObjectIdentifier: Any] = [:]
    public subscript<K: FocusedValueKey>(key: K.Type) -> K.Value? {
        get { storage[ObjectIdentifier(key)] as? K.Value }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

// MARK: - Values

// `View` conformance is what lets a Color be used directly in a ViewBuilder; everything
// else about it stays nonisolated, as the real one is.
public struct Color: Sendable, Hashable, ShapeStyle, View {
    public nonisolated init() {}
    public nonisolated init(nsColor: NSColor) {}
    public nonisolated init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {}
    public nonisolated init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public nonisolated init(white: Double, opacity: Double = 1) {}
    public nonisolated static let primary = Color()
    public nonisolated static let secondary = Color()
    public nonisolated static let accentColor = Color()
    public nonisolated static let clear = Color()
    public nonisolated static let white = Color()
    public nonisolated static let black = Color()
    public nonisolated static let red = Color()
    public nonisolated static let green = Color()
    public nonisolated static let blue = Color()
    public nonisolated static let orange = Color()
    public nonisolated static let yellow = Color()
    public nonisolated static let gray = Color()
    public nonisolated func opacity(_ value: Double) -> Color { self }
    public nonisolated var gradient: Color { self }
    @MainActor public var body: StubView { StubView() }
}

public protocol ShapeStyle {}

public struct AnyShapeStyle: ShapeStyle {
    public init(_ style: some ShapeStyle) {}
}

public struct HierarchicalShapeStyle: ShapeStyle {
    public func opacity(_ value: Double) -> HierarchicalShapeStyle { self }
}

public struct Material: ShapeStyle {
    public func opacity(_ value: Double) -> Material { self }
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var secondary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var tertiary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var quaternary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
    public static var quinary: HierarchicalShapeStyle { HierarchicalShapeStyle() }
}

extension ShapeStyle where Self == Material {
    public static var regularMaterial: Material { Material() }
    public static var thinMaterial: Material { Material() }
    public static var ultraThinMaterial: Material { Material() }
    public static var thickMaterial: Material { Material() }
    public static var bar: Material { Material() }
}

extension ShapeStyle where Self == Color {
    public nonisolated static var accentColor: Color { Color() }
    public nonisolated static var background: Color { Color() }
    public nonisolated static var clear: Color { Color() }
    public nonisolated static var white: Color { Color() }
    public nonisolated static var black: Color { Color() }
    public nonisolated static var red: Color { Color() }
    public nonisolated static var green: Color { Color() }
    public nonisolated static var blue: Color { Color() }
    public nonisolated static var orange: Color { Color() }
    public nonisolated static var gray: Color { Color() }
}

public struct Font: Sendable, Hashable {
    public static let body = Font()
    public static let callout = Font()
    public static let caption = Font()
    public static let caption2 = Font()
    public static let footnote = Font()
    public static let headline = Font()
    public static let subheadline = Font()
    public static let title = Font()
    public static let title2 = Font()
    public static let title3 = Font()
    public static let largeTitle = Font()

    public enum Weight: Sendable { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }
    public enum Design: Sendable { case `default`, serif, rounded, monospaced }
    public enum TextStyle: Sendable { case body, callout, caption, caption2, footnote, headline, subheadline, title, title2, title3, largeTitle }

    public static func system(size: CGFloat, weight: Weight = .regular, design: Design = .default) -> Font { Font() }
    public static func system(_ style: TextStyle, design: Design = .default, weight: Weight? = nil) -> Font { Font() }
    public func weight(_ weight: Weight) -> Font { self }
    public func bold() -> Font { self }
    public func italic() -> Font { self }
    public func monospaced() -> Font { self }
    public func monospacedDigit() -> Font { self }
    public func smallCaps() -> Font { self }
}

public struct Angle: Sendable { public init() {} }

public enum Edge: Sendable {
    case top, bottom, leading, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
        public static let leading = Set(rawValue: 4)
        public static let trailing = Set(rawValue: 8)
        public static let all: Set = [.top, .bottom, .leading, .trailing]
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
    }
}

public enum VerticalEdge: Sendable {
    case top, bottom
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
        public static let all: Set = [.top, .bottom]
    }
}

public enum Axis: Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
}

public struct Alignment: Sendable {
    public static let center = Alignment()
    public static let leading = Alignment()
    public static let trailing = Alignment()
    public static let top = Alignment()
    public static let bottom = Alignment()
    public static let topLeading = Alignment()
    public static let topTrailing = Alignment()
    public static let bottomLeading = Alignment()
    public static let bottomTrailing = Alignment()
}

public enum HorizontalAlignment: Sendable { case leading, center, trailing }
public enum VerticalAlignment: Sendable { case top, center, bottom, firstTextBaseline, lastTextBaseline }
public enum TextAlignment: Sendable { case leading, center, trailing }
public struct UnitPoint: Sendable, Hashable {
    public var x: CGFloat, y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

public struct Animation: Sendable {
    public static let `default` = Animation()
    public static let smooth = Animation()
    public static func easeInOut(duration: Double) -> Animation { Animation() }
    public static func easeOut(duration: Double) -> Animation { Animation() }
    public static func easeIn(duration: Double) -> Animation { Animation() }
    public static func smooth(duration: Double) -> Animation { Animation() }
    public static func linear(duration: Double) -> Animation { Animation() }
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.8) -> Animation { Animation() }
    public static let snappy = Animation()
    public static let bouncy = Animation()
    public static func snappy(duration: Double, extraBounce: Double = 0) -> Animation { Animation() }
    public static func bouncy(duration: Double, extraBounce: Double = 0) -> Animation { Animation() }
}

public struct Transaction {
    public init() {}
    public var disablesAnimations: Bool = false
    public var animation: Animation?
}

@MainActor public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

public enum AnimationCompletionCriteria: Sendable { case logicallyComplete, removed }
@MainActor public func withAnimation<Result>(_ animation: Animation? = .default, completionCriteria: AnimationCompletionCriteria = .logicallyComplete, _ body: () throws -> Result, completion: @escaping () -> Void) rethrows -> Result {
    try body()
}

@MainActor public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    try body()
}

public struct AnyTransition: Sendable {
    public static let identity = AnyTransition()
    public static let opacity = AnyTransition()
    public static let scale = AnyTransition()
    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition() }
    public static let slide = AnyTransition()
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ animation: Animation?) -> AnyTransition { self }
}

public struct ProposedViewSize: Sendable {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat?, height: CGFloat?) { self.width = width; self.height = height }
    public init(_ size: CGSize) { width = size.width; height = size.height }
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let zero = ProposedViewSize(width: 0, height: 0)
}

// MARK: - Shapes

public protocol Shape: View, Sendable {}

extension Shape {
    public var body: StubView { StubView() }
    public func fill(_ style: some ShapeStyle) -> StubView { StubView() }
    public func stroke(_ style: some ShapeStyle, lineWidth: CGFloat = 1) -> StubView { StubView() }
    public func strokeBorder(_ style: some ShapeStyle, lineWidth: CGFloat = 1) -> StubView { StubView() }
    public func inset(by amount: CGFloat) -> Self { self }
}

public struct Rectangle: Shape { public init() {} }
public struct Circle: Shape { public init() {} }
public struct Capsule: Shape { public init() {} }
public struct Ellipse: Shape { public init() {} }
public struct ConcentricRectangle: Shape { public init() {} }
public struct DefaultGlassEffectShape: Shape { public init() {} }

public struct RoundedRectangle: Shape {
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {}
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {}
}

public enum RoundedCornerStyle: Sendable { case circular, continuous }

extension Shape where Self == Rectangle {
    public static var rect: Rectangle { Rectangle() }
}

extension Shape where Self == Circle {
    public static var circle: Circle { Circle() }
}

extension Shape where Self == Capsule {
    public static var capsule: Capsule { Capsule() }
}

extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
    public static func rect(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerSize: cornerSize, style: style)
    }
}

// MARK: - Liquid Glass

public struct Glass: Sendable {
    public static let regular = Glass()
    public static let clear = Glass()
    public static let identity = Glass()
    public func tint(_ color: Color?) -> Glass { self }
    public func interactive(_ isEnabled: Bool = true) -> Glass { self }
}

@MainActor public struct GlassEffectContainer<Content: View>: View {
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

public struct GlassEffectTransition: Sendable {
    public static let matchedGeometry = GlassEffectTransition()
    public static let identity = GlassEffectTransition()
}

// MARK: - Leaf views

@MainActor public struct Text: View {
    public init(_ string: String) {}
    public init(verbatim: String) {}
    public init(_ attributed: AttributedString) {}
    public init<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String {}
    public init(_ date: Date, style: DateStyle) {}

    public struct DateStyle: Sendable {
        public static let time = DateStyle()
        public static let date = DateStyle()
        public static let relative = DateStyle()
        public static let offset = DateStyle()
    }

    public enum LineStyle: Sendable { case single, double }

    public var body: StubView { StubView() }

    public func font(_ font: Font?) -> Text { self }
    public func foregroundStyle(_ style: some ShapeStyle) -> Text { self }
    public func bold() -> Text { self }
    public func italic(_ isActive: Bool = true) -> Text { self }
    public func monospacedDigit() -> Text { self }
    public func strikethrough(_ isActive: Bool = true) -> Text { self }
    public func underline(_ isActive: Bool = true) -> Text { self }
    public func customAttribute<T: TextAttribute>(_ value: T) -> Text { self }
    public static func + (lhs: Text, rhs: Text) -> Text { lhs }

    public struct Layout: Sequence {
        public struct Line: Sequence {
            public func makeIterator() -> IndexingIterator<[Run]> { [Run]().makeIterator() }
        }
        public struct Run {
            public var typographicBounds: TypographicBounds { TypographicBounds() }
            public subscript<T: TextAttribute>(_ type: T.Type) -> T? { nil }
        }
        public struct TypographicBounds {
            public var rect: CGRect = .zero
            public var ascent: CGFloat = 0
            public var descent: CGFloat = 0
            public var leading: CGFloat = 0
        }
        public func makeIterator() -> IndexingIterator<[Line]> { [Line]().makeIterator() }
    }
}

public protocol TextAttribute {}

public protocol TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext)
}

public struct GraphicsContext {
    public enum Shading {
        case color(Color)
    }
    public mutating func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {}
    public mutating func draw(_ run: Text.Layout.Run) {}
}

public struct Path {
    public init() {}
    public mutating func move(to point: CGPoint) {}
    public mutating func addLine(to point: CGPoint) {}
}

public enum CoordinateSpace: Sendable {
    case local, global
}

public enum HoverPhase: Sendable {
    case active(CGPoint)
    case ended
}

@MainActor public struct Image: View {
    public init(systemName: String) {}
    public init(nsImage: NSImage) {}
    public init(_ name: String) {}
    public init(decorative: String) {}
    public var body: StubView { StubView() }
    public func resizable() -> Image { self }
    public func renderingMode(_ mode: TemplateRenderingMode) -> Image { self }
    public func interpolation(_ interpolation: Interpolation) -> Image { self }
    public enum TemplateRenderingMode: Sendable { case original, template }
    public enum Interpolation: Sendable { case none, low, medium, high }
}

public enum SymbolRenderingMode: Sendable { case monochrome, hierarchical, palette, multicolor }

@MainActor public struct Label<Title: View, Icon: View>: View {
    public init(_ title: String, systemImage: String) where Title == Text, Icon == Image {}
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
    public var body: StubView { StubView() }
}

public struct LabelStyleShim: Sendable {
    public static let automatic = LabelStyleShim()
    public static let titleOnly = LabelStyleShim()
    public static let iconOnly = LabelStyleShim()
    public static let titleAndIcon = LabelStyleShim()
}

@MainActor public struct Spacer: View {
    public init(minLength: CGFloat? = nil) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Divider: View {
    public init() {}
    public var body: StubView { StubView() }
}

@MainActor public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    public init() where Label == EmptyView, CurrentValueLabel == EmptyView {}
    public init(_ title: String) where Label == Text, CurrentValueLabel == EmptyView {}
    public init(value: Double?, total: Double = 1) where Label == EmptyView, CurrentValueLabel == EmptyView {}
    public init(value: Double?, total: Double = 1, @ViewBuilder label: () -> Label) where CurrentValueLabel == EmptyView {}
    public var body: StubView { StubView() }
}

public struct ProgressViewStyleShim: Sendable {
    public static let automatic = ProgressViewStyleShim()
    public static let linear = ProgressViewStyleShim()
    public static let circular = ProgressViewStyleShim()
}

@MainActor public struct Button<Label: View>: View {
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(_ title: String, action: @escaping () -> Void) where Label == Text {}
    public init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) where Label == Text {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
    public init(_ title: String, systemImage: String, action: @escaping () -> Void) where Label == Text {}
    public var body: StubView { StubView() }
}

public struct ButtonRole: Sendable, Equatable {
    public static let destructive = ButtonRole()
    public static let cancel = ButtonRole()
}

public struct ButtonStyleShim: Sendable {
    public static let automatic = ButtonStyleShim()
    public static let plain = ButtonStyleShim()
    public static let borderless = ButtonStyleShim()
    public static let bordered = ButtonStyleShim()
    public static let borderedProminent = ButtonStyleShim()
    public static let link = ButtonStyleShim()
    public static let glass = ButtonStyleShim()
    public static let glassProminent = ButtonStyleShim()
    public static let accessoryBar = ButtonStyleShim()
}

public struct ButtonBorderShape: Sendable {
    public static let automatic = ButtonBorderShape()
    public static let capsule = ButtonBorderShape()
    public static let circle = ButtonBorderShape()
    public static let roundedRectangle = ButtonBorderShape()
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { ButtonBorderShape() }
}

public struct MenuStyleShim: Sendable {
    public static let automatic = MenuStyleShim()
    public static let button = MenuStyleShim()
    public static let borderlessButton = MenuStyleShim()
}

public struct PickerStyleShim: Sendable {
    public static let automatic = PickerStyleShim()
    public static let segmented = PickerStyleShim()
    public static let menu = PickerStyleShim()
    public static let radioGroup = PickerStyleShim()
    public static let inline = PickerStyleShim()
}

public struct TextFieldStyleShim: Sendable {
    public static let automatic = TextFieldStyleShim()
    public static let plain = TextFieldStyleShim()
    public static let roundedBorder = TextFieldStyleShim()
    public static let squareBorder = TextFieldStyleShim()
}

public struct ListStyleShim: Sendable {
    public static let automatic = ListStyleShim()
    public static let plain = ListStyleShim()
    public static let sidebar = ListStyleShim()
    public static let inset = ListStyleShim()
    public static let bordered = ListStyleShim()
}

public struct FormStyleShim: Sendable {
    public static let automatic = FormStyleShim()
    public static let grouped = FormStyleShim()
    public static let columns = FormStyleShim()
}

public struct ControlSize: Sendable {
    public static let mini = ControlSize()
    public static let small = ControlSize()
    public static let regular = ControlSize()
    public static let large = ControlSize()
    public static let extraLarge = ControlSize()
}

public struct TextSelectabilityShim: Sendable {
    public static let enabled = TextSelectabilityShim()
    public static let disabled = TextSelectabilityShim()
}

// MARK: - Containers

@MainActor public struct VStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct HStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct ZStack<Content: View>: View {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct LazyVStack<Content: View>: View {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct LazyHStack<Content: View>: View {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 2)
}

public struct GridItem: Sendable {
    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
}

@MainActor public struct LazyVGrid<Content: View>: View {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Group<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public init<Base: View>(subviews view: Base, @ViewBuilder transform: @escaping (SubviewsCollection) -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Subview: View, Identifiable {
    public struct ID: Hashable, Sendable {}
    public nonisolated var id: ID { ID() }
    public var body: StubView { StubView() }
}

public struct SubviewsCollection: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(position: Int) -> Subview { Subview() }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }
}

@MainActor public struct ScrollView<Content: View>: View {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct ScrollViewReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct ScrollViewProxy {
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {}
}

public struct ToolbarDefaultItemKind: Sendable {
    public static let title = ToolbarDefaultItemKind()
    public static let sidebarToggle = ToolbarDefaultItemKind()
}

public struct Gradient: Sendable {
    public struct Stop: Sendable {
        public init(color: Color, location: CGFloat) {}
    }
    public init(colors: [Color]) {}
    public init(stops: [Stop]) {}
}

public struct LinearGradient: ShapeStyle, View {
    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {}
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {}
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {}
    public var body: StubView { StubView() }
}

public enum ScrollPhase: Equatable, Sendable {
    case idle, tracking, interacting, decelerating, animating
}

public struct GeometryProxy: Sendable {
    public var size: CGSize { .zero }
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }
    public subscript<T>(anchor: Anchor<T>) -> T { anchor.value }
}

@MainActor public struct GeometryReader<Content: View>: View {
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) {}
    public var body: StubView { StubView() }
}

public struct Anchor<Value>: Sendable where Value: Sendable {
    let value: Value
    public struct Source: Sendable {
        public static var bounds: Anchor<CGRect>.Source { Anchor<CGRect>.Source() }
    }
}

public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

public struct ScrollGeometry: Equatable, Sendable {
    public var contentOffset: CGPoint = .zero
    public var contentSize: CGSize = .zero
    public var containerSize: CGSize = .zero
    public var visibleRect: CGRect = .zero
    public var contentInsets: EdgeInsetsShim = EdgeInsetsShim()
}

public struct EdgeInsetsShim: Equatable, Sendable {
    public var top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0
    public init() {}
}

public struct EdgeInsets: Equatable, Sendable {
    public var top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat
    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
}

public struct ScrollBounceBehavior: Sendable {
    public static let automatic = ScrollBounceBehavior()
    public static let always = ScrollBounceBehavior()
    public static let basedOnSize = ScrollBounceBehavior()
}

public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
    public static let all: SafeAreaRegions = [.container, .keyboard]
}

public struct ScrollEdgeEffectStyle: Sendable {
    public static let automatic = ScrollEdgeEffectStyle()
    public static let soft = ScrollEdgeEffectStyle()
    public static let hard = ScrollEdgeEffectStyle()
}

@MainActor public struct ForEach<Data, ID, Content>: View where Data: RandomAccessCollection, ID: Hashable {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content)
        where Data.Element: Identifiable, ID == Data.Element.ID {}
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content)
        where Data == Range<Int>, ID == Int {}
    public var body: StubView { StubView() }
}

@MainActor public struct Section<Parent: View, Content: View, Footer: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) where Footer == EmptyView {}
    public init(@ViewBuilder content: () -> Content) where Parent == EmptyView, Footer == EmptyView {}
    public init(_ title: String, @ViewBuilder content: () -> Content) where Parent == Text, Footer == EmptyView {}
    public var body: StubView { StubView() }
}

@MainActor public struct List<SelectionValue: Hashable, Content: View>: View {
    public init(@ViewBuilder content: () -> Content) where SelectionValue == Never {}
    public init(selection: Binding<SelectionValue?>, @ViewBuilder content: () -> Content) {}
    public init(selection: Binding<Set<SelectionValue>>, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Form<Content: View>: View {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct LabeledContent<Label: View, Content: View>: View {
    public init(_ title: String, value: String) where Label == Text, Content == Text {}
    public init(_ title: String, @ViewBuilder content: () -> Content) where Label == Text {}
    public var body: StubView { StubView() }
}

@MainActor public struct TextField<Label: View>: View {
    public init(_ title: String, text: Binding<String>) where Label == Text {}
    public init(_ title: String, text: Binding<String>, axis: Axis) where Label == Text {}
    public init(_ title: String, text: Binding<String>, prompt: Text?) where Label == Text {}
    public var body: StubView { StubView() }
}

@MainActor public struct SecureField<Label: View>: View {
    public init(_ title: String, text: Binding<String>) where Label == Text {}
    public var body: StubView { StubView() }
}

@MainActor public struct Toggle<Label: View>: View {
    public init(_ title: String, isOn: Binding<Bool>) where Label == Text {}
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    public init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) where Label == Text {}
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Menu<Label: View, Content: View>: View {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
    public init(_ title: String, @ViewBuilder content: () -> Content) where Label == Text {}
    public var body: StubView { StubView() }
}

@MainActor public struct TabView<SelectionValue: Hashable, Content: View>: View {
    public init(@ViewBuilder content: () -> Content) where SelectionValue == Never {}
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    public var body: StubView { StubView() }
}

@MainActor public struct Tab<Value: Hashable, Content: View, TabLabel: View>: View {
    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content)
        where Value == Never, TabLabel == DefaultTabLabel {}
    public init(_ title: String, systemImage: String, value: Value, @ViewBuilder content: () -> Content)
        where TabLabel == DefaultTabLabel {}
    public var body: StubView { StubView() }
}

public struct DefaultTabLabel: View {
    public var body: StubView { StubView() }
}

@MainActor public struct ContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    public init(_ title: String, systemImage: String) where Label == Text, Description == EmptyView, Actions == EmptyView {}
    public init(_ title: String, systemImage: String, description: Text) where Label == Text, Description == Text, Actions == EmptyView {}
    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description) where Actions == EmptyView {}
    public var body: StubView { StubView() }
}

extension ContentUnavailableView where Label == StubView, Description == StubView, Actions == StubView {
    @MainActor public static func search(text: String) -> ContentUnavailableView { fatalError() }
}

public enum NavigationSplitViewVisibility: Sendable {
    case all, doubleColumn, detailOnly, automatic
}

@MainActor public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) where Content == EmptyView {}
    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) where Content == EmptyView {}
    public var body: StubView { StubView() }
}

// MARK: - Modifiers
//
// Almost all of these return an opaque view: the stub only needs the *names and labels* to
// be right, not the types.

extension View {
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> StubView { StubView() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> StubView { StubView() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> StubView { StubView() }
    public func fixedSize() -> StubView { StubView() }
    public func padding(_ length: CGFloat) -> StubView { StubView() }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> StubView { StubView() }
    public func padding(_ insets: EdgeInsets) -> StubView { StubView() }
    public func scenePadding() -> StubView { StubView() }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> StubView { StubView() }
    public func position(x: CGFloat, y: CGFloat) -> StubView { StubView() }
    public func layoutPriority(_ value: Double) -> StubView { StubView() }

    public func font(_ font: Font?) -> StubView { StubView() }
    public func foregroundStyle(_ style: some ShapeStyle) -> StubView { StubView() }
    public func foregroundColor(_ color: Color?) -> StubView { StubView() }
    public func tint(_ color: Color?) -> StubView { StubView() }
    public func opacity(_ value: Double) -> StubView { StubView() }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode) -> StubView { StubView() }
    public func imageScale(_ scale: ImageScale) -> StubView { StubView() }
    public func lineLimit(_ number: Int?) -> StubView { StubView() }
    public func lineLimit(_ limit: Int, reservesSpace: Bool) -> StubView { StubView() }
    public func lineLimit(_ limit: ClosedRange<Int>) -> StubView { StubView() }
    public func lineSpacing(_ value: CGFloat) -> StubView { StubView() }
    public func truncationMode(_ mode: TextTruncationMode) -> StubView { StubView() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> StubView { StubView() }
    public func minimumScaleFactor(_ factor: CGFloat) -> StubView { StubView() }
    public func textSelection(_ selectability: TextSelectabilityShim) -> StubView { StubView() }
    public func monospacedDigit() -> StubView { StubView() }
    public func italic(_ isActive: Bool = true) -> StubView { StubView() }
    public func bold(_ isActive: Bool = true) -> StubView { StubView() }
    public func labelsHidden() -> StubView { StubView() }
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> StubView { StubView() }
    public func badge(_ count: Int) -> StubView { StubView() }

    public func background(_ style: some ShapeStyle) -> StubView { StubView() }
    public func background(_ style: some ShapeStyle, in shape: some Shape) -> StubView { StubView() }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> StubView { StubView() }
    public func overlay(_ style: some ShapeStyle) -> StubView { StubView() }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> StubView { StubView() }
    public func anchorPreference<A, K: PreferenceKey>(key: K.Type, value: Anchor<A>.Source, transform: @escaping (Anchor<A>) -> K.Value) -> StubView { StubView() }
    public func overlayPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, @ViewBuilder _ transform: @escaping (K.Value) -> V) -> StubView { StubView() }
    public func onLongPressGesture(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10, perform action: @escaping () -> Void) -> StubView { StubView() }
    public func scaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center) -> StubView { StubView() }
    public func clipShape(_ shape: some Shape) -> StubView { StubView() }
    public func clipped() -> StubView { StubView() }
    public func cornerRadius(_ radius: CGFloat) -> StubView { StubView() }
    public func shadow(color: Color = .black, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> StubView { StubView() }
    public func mask<V: View>(@ViewBuilder _ mask: () -> V) -> StubView { StubView() }
    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> StubView { StubView() }
    public func compositingGroup() -> StubView { StubView() }
    public func drawingGroup() -> StubView { StubView() }
    public func blur(radius: CGFloat) -> StubView { StubView() }
    public func ignoresSafeArea() -> StubView { StubView() }
    public func safeAreaInset<V: View>(edge: Edge, alignment: Alignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> StubView { StubView() }
    public func ignoresSafeArea(_ regions: SafeAreaRegions, edges: Edge.Set = .all) -> StubView { StubView() }
    public func safeAreaBar<V: View>(edge: Edge, alignment: Alignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> StubView { StubView() }
    public func matchedGeometryEffect(id: some Hashable, in namespace: Namespace.ID) -> StubView { StubView() }

    public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> StubView { StubView() }
    public func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> StubView { StubView() }
    public func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> StubView { StubView() }
    public func glassEffectTransition(_ transition: GlassEffectTransition) -> StubView { StubView() }
    public func backgroundExtensionEffect() -> StubView { StubView() }

    public func buttonStyle(_ style: ButtonStyleShim) -> StubView { StubView() }
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> StubView { StubView() }
    public func menuStyle(_ style: MenuStyleShim) -> StubView { StubView() }
    public func menuIndicator(_ visibility: Visibility) -> StubView { StubView() }
    public func pickerStyle(_ style: PickerStyleShim) -> StubView { StubView() }
    public func textFieldStyle(_ style: TextFieldStyleShim) -> StubView { StubView() }
    public func listStyle(_ style: ListStyleShim) -> StubView { StubView() }
    public func formStyle(_ style: FormStyleShim) -> StubView { StubView() }
    public func progressViewStyle(_ style: ProgressViewStyleShim) -> StubView { StubView() }
    public func labelStyle(_ style: LabelStyleShim) -> StubView { StubView() }
    public func controlSize(_ size: ControlSize) -> StubView { StubView() }

    public func disabled(_ isDisabled: Bool) -> StubView { StubView() }
    public func hidden() -> StubView { StubView() }
    public func allowsHitTesting(_ enabled: Bool) -> StubView { StubView() }
    public func contentShape(_ shape: some Shape) -> StubView { StubView() }
    public func help(_ text: String) -> StubView { StubView() }
    public func textRenderer<T: TextRenderer>(_ renderer: T) -> StubView { StubView() }
    public func onContinuousHover(coordinateSpace: CoordinateSpace = .local, perform action: @escaping (HoverPhase) -> Void) -> StubView { StubView() }
    public func tag<V: Hashable>(_ tag: V) -> StubView { StubView() }
    public func id<ID: Hashable>(_ id: ID) -> StubView { StubView() }
    public func transition(_ transition: AnyTransition) -> StubView { StubView() }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> StubView { StubView() }
    public func zIndex(_ value: Double) -> StubView { StubView() }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> StubView { StubView() }
    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> StubView { StubView() }

    public func onAppear(perform action: (() -> Void)? = nil) -> StubView { StubView() }
    public func onDisappear(perform action: (() -> Void)? = nil) -> StubView { StubView() }
    public func onHover(perform action: @escaping (Bool) -> Void) -> StubView { StubView() }
    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> StubView { StubView() }
    public func onSubmit(_ action: @escaping () -> Void) -> StubView { StubView() }
    public func onExitCommand(perform action: @escaping () -> Void) -> StubView { StubView() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> StubView { StubView() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> StubView { StubView() }
    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> StubView { StubView() }
    public func task(priority: TaskPriority = .userInitiated, @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> StubView { StubView() }
    public func task<T: Equatable>(id: T, priority: TaskPriority = .userInitiated, @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> StubView { StubView() }
    public func onKeyPress(_ key: KeyEquivalent, action: @escaping () -> KeyPress.Result) -> StubView { StubView() }
    public func onKeyPress(phases: KeyPress.Phases, action: @escaping (KeyPress) -> KeyPress.Result) -> StubView { StubView() }

    public func focused(_ condition: FocusStateBinding<Bool>) -> StubView { StubView() }
    public func focused<V: Hashable>(_ binding: FocusStateBinding<V?>, equals value: V) -> StubView { StubView() }
    public func searchFocused(_ condition: FocusStateBinding<Bool>) -> StubView { StubView() }
    public func focusedSceneValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T?) -> StubView { StubView() }
    public func focusedValue<T>(_ keyPath: WritableKeyPath<FocusedValues, T?>, _ value: T?) -> StubView { StubView() }

    public func environment<T>(_ keyPath: WritableKeyPath<EnvironmentValues, T>, _ value: T) -> StubView { StubView() }
    public func environment<T: AnyObject>(_ object: T?) -> StubView { StubView() }

    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> StubView { StubView() }
    public func popover<C: View>(isPresented: Binding<Bool>, attachmentAnchor: PopoverAttachmentAnchor = .rect, arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> C) -> StubView { StubView() }
    public func sheet<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> C) -> StubView { StubView() }
    public func sheet<Item: Identifiable, C: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> C) -> StubView { StubView() }
    public func confirmationDialog<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> StubView { StubView() }
    public func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> StubView { StubView() }
    public func inspector<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> C) -> StubView { StubView() }
    public func inspectorColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> StubView { StubView() }

    public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: String? = nil) -> StubView { StubView() }

    public func navigationTitle(_ title: String) -> StubView { StubView() }
    public func navigationSubtitle(_ subtitle: String) -> StubView { StubView() }
    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> StubView { StubView() }
    public func toolbar<C: ToolbarContent>(@ToolbarContentBuilder content: () -> C) -> StubView { StubView() }

    public func scrollContentBackground(_ visibility: Visibility) -> StubView { StubView() }
    public func toolbar(removing kind: ToolbarDefaultItemKind?) -> StubView { StubView() }
    public func toolbarBackgroundVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> StubView { StubView() }
    public func listRowInsets(_ insets: EdgeInsets?) -> StubView { StubView() }
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> StubView { StubView() }
    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = .vertical) -> StubView { StubView() }
    public func scrollTargetLayout() -> StubView { StubView() }
    public func defaultScrollAnchor(_ anchor: UnitPoint?) -> StubView { StubView() }
    public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> StubView { StubView() }
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping (T) -> Void) -> StubView { StubView() }
    public func onScrollGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (ScrollGeometry) -> T, action: @escaping (T, T) -> Void) -> StubView { StubView() }
    public func onScrollPhaseChange(_ action: @escaping (ScrollPhase, ScrollPhase) -> Void) -> StubView { StubView() }

    public func dropDestination<T>(for payloadType: T.Type, action: @escaping ([T], CGPoint) -> Bool, isTargeted: @escaping (Bool) -> Void) -> StubView { StubView() }
    public func draggable<T>(_ payload: @autoclosure @escaping () -> T) -> StubView { StubView() }

    public func accessibilityLabel(_ label: String) -> StubView { StubView() }
    public func accessibilityValue(_ value: String) -> StubView { StubView() }
    public func accessibilityHint(_ hint: String) -> StubView { StubView() }
    public func accessibilityHidden(_ hidden: Bool) -> StubView { StubView() }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> StubView { StubView() }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> StubView { StubView() }
}

public enum ContentMode: Sendable { case fit, fill }
public enum TextTruncationMode: Sendable { case head, tail, middle }
public enum Visibility: Sendable { case automatic, visible, hidden }
public struct ToolbarPlacement: Sendable {
    public static let automatic = ToolbarPlacement()
    public static let windowToolbar = ToolbarPlacement()
}
public enum ImageScale: Sendable { case small, medium, large }
public struct PopoverAttachmentAnchor: Sendable { public static let rect = PopoverAttachmentAnchor() }
public struct AccessibilityChildBehavior: Sendable {
    public static let ignore = AccessibilityChildBehavior()
    public static let combine = AccessibilityChildBehavior()
    public static let contain = AccessibilityChildBehavior()
}
public struct AccessibilityTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1)
    public static let isHeader = AccessibilityTraits(rawValue: 2)
    public static let isSelected = AccessibilityTraits(rawValue: 4)
}

public struct SearchFieldPlacement: Sendable {
    public static let automatic = SearchFieldPlacement()
    public static let sidebar = SearchFieldPlacement()
    public static let toolbar = SearchFieldPlacement()
}

public struct KeyEquivalent: Sendable, Hashable, ExpressibleByExtendedGraphemeClusterLiteral {
    public init(_ character: Character) {}
    public init(extendedGraphemeClusterLiteral value: Character) {}
    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let `return` = KeyEquivalent("\r")
    public static let delete = KeyEquivalent("\u{8}")
    public static let space = KeyEquivalent(" ")
    public static let tab = KeyEquivalent("\t")
}

public struct EventModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = EventModifiers(rawValue: 1)
    public static let shift = EventModifiers(rawValue: 2)
    public static let option = EventModifiers(rawValue: 4)
    public static let control = EventModifiers(rawValue: 8)
    public static let all: EventModifiers = [.command, .shift, .option, .control]
}

public struct KeyboardShortcut: Sendable {
    public static let defaultAction = KeyboardShortcut()
    public static let cancelAction = KeyboardShortcut()
}

public struct KeyPress: Sendable {
    public enum Result: Sendable { case handled, ignored }
    public struct Phases: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let down = Phases(rawValue: 1)
        public static let up = Phases(rawValue: 2)
        public static let repeat_ = Phases(rawValue: 4)
    }
    public let key: KeyEquivalent = .space
    public let modifiers: EventModifiers = []
}

// MARK: - Toolbar

@MainActor public protocol ToolbarContent {
    associatedtype Body: ToolbarContent
    @ToolbarContentBuilder var body: Body { get }
}

public struct StubToolbarContent: ToolbarContent {
    public init() {}
    public var body: StubToolbarContent { self }
}

public struct OptionalToolbarContent<C: ToolbarContent>: ToolbarContent {
    public init() {}
    public var body: StubToolbarContent { StubToolbarContent() }
}

public struct ConditionalToolbarContent<T: ToolbarContent, F: ToolbarContent>: ToolbarContent {
    public init() {}
    public var body: StubToolbarContent { StubToolbarContent() }
}

@resultBuilder public enum ToolbarContentBuilder {
    @MainActor public static func buildBlock() -> StubToolbarContent { StubToolbarContent() }
    @MainActor public static func buildBlock<C: ToolbarContent>(_ content: C) -> C { content }
    @MainActor public static func buildPartialBlock<C: ToolbarContent>(first: C) -> C { first }
    @MainActor public static func buildPartialBlock<A: ToolbarContent, N: ToolbarContent>(accumulated: A, next: N) -> StubToolbarContent { StubToolbarContent() }
    @MainActor public static func buildOptional<C: ToolbarContent>(_ content: C?) -> OptionalToolbarContent<C> { OptionalToolbarContent() }
    @MainActor public static func buildEither<T: ToolbarContent, F: ToolbarContent>(first: T) -> ConditionalToolbarContent<T, F> { ConditionalToolbarContent() }
    @MainActor public static func buildEither<T: ToolbarContent, F: ToolbarContent>(second: F) -> ConditionalToolbarContent<T, F> { ConditionalToolbarContent() }
    @MainActor public static func buildExpression<C: ToolbarContent>(_ expression: C) -> C { expression }
}

public struct ToolbarItemPlacement: Sendable {
    public static let automatic = ToolbarItemPlacement()
    public static let primaryAction = ToolbarItemPlacement()
    public static let status = ToolbarItemPlacement()
    public static let navigation = ToolbarItemPlacement()
    public static let principal = ToolbarItemPlacement()
    public static let confirmationAction = ToolbarItemPlacement()
    public static let cancellationAction = ToolbarItemPlacement()
}

@MainActor public struct ToolbarItem<ID, Content: View>: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == Void {}
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == String {}
    public var body: StubToolbarContent { StubToolbarContent() }
}

@MainActor public struct ToolbarItemGroup<Content: View>: ToolbarContent {
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {}
    public var body: StubToolbarContent { StubToolbarContent() }
}

public struct SpacerSizing: Sendable {
    public static let flexible = SpacerSizing()
    public static let fixed = SpacerSizing()
}

@MainActor public struct ToolbarSpacer: ToolbarContent {
    public init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic) {}
    public var body: StubToolbarContent { StubToolbarContent() }
}

extension ToolbarContent {
    public func sharedBackgroundVisibility(_ visibility: Visibility) -> StubToolbarContent { StubToolbarContent() }
}

// MARK: - Scenes, commands and the app

@MainActor public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}

public struct StubScene: Scene {
    public init() {}
    public var body: StubScene { self }
}

@resultBuilder public enum SceneBuilder {
    @MainActor public static func buildBlock<C: Scene>(_ content: C) -> C { content }
    @MainActor public static func buildPartialBlock<C: Scene>(first: C) -> C { first }
    @MainActor public static func buildPartialBlock<A: Scene, N: Scene>(accumulated: A, next: N) -> StubScene { StubScene() }
    @MainActor public static func buildExpression<C: Scene>(_ expression: C) -> C { expression }
}

extension Scene {
    public func commands<C: Commands>(@CommandsBuilder content: () -> C) -> StubScene { StubScene() }
    public func defaultSize(width: CGFloat, height: CGFloat) -> StubScene { StubScene() }
    public func defaultPosition(_ position: UnitPoint) -> StubScene { StubScene() }
    public func windowResizability(_ resizability: WindowResizability) -> StubScene { StubScene() }
    public func windowToolbarStyle(_ style: WindowToolbarStyleShim) -> StubScene { StubScene() }
    public func windowStyle(_ style: WindowStyleShim) -> StubScene { StubScene() }
    public func handlesExternalEvents(matching: Set<String>) -> StubScene { StubScene() }
}

public struct WindowResizability: Sendable {
    public static let automatic = WindowResizability()
    public static let contentSize = WindowResizability()
    public static let contentMinSize = WindowResizability()
}

public struct WindowToolbarStyleShim: Sendable {
    public static let automatic = WindowToolbarStyleShim()
    public static let unified = WindowToolbarStyleShim()
    public static let unifiedCompact = WindowToolbarStyleShim()
    public static let expanded = WindowToolbarStyleShim()
}

public struct WindowStyleShim: Sendable {
    public static let automatic = WindowStyleShim()
    public static let hiddenTitleBar = WindowStyleShim()
    public static let titleBar = WindowStyleShim()
}

@MainActor public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    public init(id: String, @ViewBuilder content: () -> Content) {}
    public init(_ title: String, @ViewBuilder content: () -> Content) {}
    public var body: StubScene { StubScene() }
}

@MainActor public struct Window<Content: View>: Scene {
    public init(_ title: String, id: String, @ViewBuilder content: () -> Content) {}
    public var body: StubScene { StubScene() }
}

@MainActor public struct Settings<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
    public var body: StubScene { StubScene() }
}

@MainActor public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Body { get }
}

public struct StubCommands: Commands {
    public init() {}
    public var body: StubCommands { self }
}

public struct OptionalCommands<C: Commands>: Commands {
    public init() {}
    public var body: StubCommands { StubCommands() }
}

@resultBuilder public enum CommandsBuilder {
    @MainActor public static func buildBlock() -> StubCommands { StubCommands() }
    @MainActor public static func buildBlock<C: Commands>(_ content: C) -> C { content }
    @MainActor public static func buildPartialBlock<C: Commands>(first: C) -> C { first }
    @MainActor public static func buildPartialBlock<A: Commands, N: Commands>(accumulated: A, next: N) -> StubCommands { StubCommands() }
    @MainActor public static func buildOptional<C: Commands>(_ content: C?) -> OptionalCommands<C> { OptionalCommands() }
    @MainActor public static func buildExpression<C: Commands>(_ expression: C) -> C { expression }
}

public struct CommandGroupPlacement: Sendable {
    public static let newItem = CommandGroupPlacement()
    public static let appInfo = CommandGroupPlacement()
    public static let appSettings = CommandGroupPlacement()
    public static let textEditing = CommandGroupPlacement()
    public static let textFormatting = CommandGroupPlacement()
    public static let pasteboard = CommandGroupPlacement()
    public static let undoRedo = CommandGroupPlacement()
    public static let help = CommandGroupPlacement()
    public static let sidebar = CommandGroupPlacement()
    public static let toolbar = CommandGroupPlacement()
    public static let windowList = CommandGroupPlacement()
    public static let saveItem = CommandGroupPlacement()
    public static let importExport = CommandGroupPlacement()
    public static let printItem = CommandGroupPlacement()
    public static let systemServices = CommandGroupPlacement()
    public static let singleWindowList = CommandGroupPlacement()
    public static let windowSize = CommandGroupPlacement()
    public static let windowArrangement = CommandGroupPlacement()
}

@MainActor public struct CommandGroup<Content: View>: Commands {
    public init(replacing placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(after placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(before placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public var body: StubCommands { StubCommands() }
}

@MainActor public struct CommandMenu<Content: View>: Commands {
    public init(_ name: String, @ViewBuilder content: () -> Content) {}
    public var body: StubCommands { StubCommands() }
}

// Main-actor isolated, as the real one is — which is what lets `@State private var model =
// Model()` work when `Model` is itself main-actor isolated.
@MainActor public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}

extension App {
    @MainActor public static func main() {}
}

@propertyWrapper public struct NSApplicationDelegateAdaptor<Delegate: NSObject> {
    public var wrappedValue: Delegate
    public init(_ type: Delegate.Type) {
        // The stub never actually instantiates the delegate.
        wrappedValue = unsafeDowncast(NSObject(), to: Delegate.self)
    }
}

// MARK: - Layout

public protocol Layout: Sendable {
    associatedtype Cache = Void
    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout Cache)
    func makeCache(subviews: LayoutSubviews) -> Cache
}

extension Layout where Cache == Void {
    public func makeCache(subviews: LayoutSubviews) -> Void { () }
}

extension Layout {
    public typealias Subviews = LayoutSubviews
    @MainActor public func callAsFunction<V: View>(@ViewBuilder _ content: () -> V) -> StubView { StubView() }
}

public struct LayoutSubviews: RandomAccessCollection, Sendable {
    public typealias Element = LayoutSubview
    public typealias Index = Int
    public var startIndex: Int { 0 }
    public var endIndex: Int { 0 }
    public subscript(position: Int) -> LayoutSubview { LayoutSubview() }
}

public struct LayoutSubview: Sendable {
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { .zero }
    public func place(at position: CGPoint, anchor: UnitPoint = .center, proposal: ProposedViewSize) {}
    public var priority: Double { 0 }
}

// MARK: - AppKit bridging

@MainActor public protocol NSViewRepresentable: View {
    associatedtype NSViewType
    associatedtype Coordinator = Void
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    func makeCoordinator() -> Coordinator
    typealias Context = NSViewRepresentableContext<Self>
}

extension NSViewRepresentable {
    public var body: StubView { StubView() }
}

extension NSViewRepresentable where Coordinator == Void {
    public func makeCoordinator() -> Void { () }
}

public struct NSViewRepresentableContext<Representable: NSViewRepresentable> {
    public var coordinator: Representable.Coordinator
    public var environment: EnvironmentValues { EnvironmentValues() }
}

@MainActor public protocol NSViewControllerRepresentable: View {
    associatedtype NSViewControllerType
    associatedtype Coordinator = Void
}

// MARK: - AttributedString

// Swift Foundation on Linux ships `AttributedString` with its own attribute scope, so
// `link` already resolves. What it does not ship is SwiftUI's scope (`font`,
// `foregroundColor`, `backgroundColor`, `underlineStyle`) or Markdown parsing. Both are
// declared here against the real `AttributedString`, so the app's rendering code is
// type-checked against the same shapes it will see on macOS.

public enum FontAttribute: AttributedStringKey {
    public typealias Value = Font
    public static let name = "SwiftUI.Font"
}

public enum ForegroundColorAttribute: AttributedStringKey {
    public typealias Value = Color
    public static let name = "SwiftUI.ForegroundColor"
}

public enum BackgroundColorAttribute: AttributedStringKey {
    public typealias Value = Color
    public static let name = "SwiftUI.BackgroundColor"
}

public enum UnderlineStyleAttribute: AttributedStringKey {
    public typealias Value = Text.LineStyle
    public static let name = "SwiftUI.UnderlineStyle"
}

public enum StrikethroughStyleAttribute: AttributedStringKey {
    public typealias Value = Text.LineStyle
    public static let name = "SwiftUI.StrikethroughStyle"
}

extension AttributeScopes {
    public struct SwiftUIAttributes: AttributeScope {
        public let font: FontAttribute
        public let foregroundColor: ForegroundColorAttribute
        public let backgroundColor: BackgroundColorAttribute
        public let underlineStyle: UnderlineStyleAttribute
        public let strikethroughStyle: StrikethroughStyleAttribute
        public let foundation: FoundationAttributes
    }

    public var swiftUI: SwiftUIAttributes.Type { SwiftUIAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUIAttributes, T>
    ) -> T {
        self[T.self]
    }
}

extension AttributedString {
    public struct MarkdownParsingOptions: Sendable {
        public enum InterpretedSyntax: Sendable {
            case full
            case inlineOnly
            case inlineOnlyPreservingWhitespace
        }

        public enum FailurePolicy: Sendable {
            case returnError
            case returnPartiallyParsedIfPossible
        }

        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy
        public var languageCode: String?

        public init(
            allowsExtendedAttributes: Bool = false,
            interpretedSyntax: InterpretedSyntax = .full,
            failurePolicy: FailurePolicy = .returnError,
            languageCode: String? = nil
        ) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
            self.languageCode = languageCode
        }
    }

    public init(markdown: String, options: MarkdownParsingOptions) throws {
        self.init(markdown)
    }
}

/// Lives here rather than in the AppKit stub because it is generic over `View`, which only
/// this module declares.
@MainActor open class NSHostingView<Content: View>: NSView {
    public init(rootView: Content) { super.init(frame: .zero) }
}
