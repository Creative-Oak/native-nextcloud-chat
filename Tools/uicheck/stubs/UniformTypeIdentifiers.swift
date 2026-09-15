// Stand-in for UniformTypeIdentifiers.
public struct UTType: Sendable, Hashable {
    public let identifier: String
    public init(_ identifier: String) { self.identifier = identifier }
    public static let image = UTType("public.image")
    public static let fileURL = UTType("public.file-url")
    public static let item = UTType("public.item")
    public static let png = UTType("public.png")
    public static let jpeg = UTType("public.jpeg")
}
