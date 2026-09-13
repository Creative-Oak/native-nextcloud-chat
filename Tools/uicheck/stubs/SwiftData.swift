// A stand-in for SwiftData's container types.
//
// `@Model` and `@ModelActor` are compiler macros that only exist on Apple platforms, so the
// storage layer itself can't be checked here — but the container API the app touches can.
@_exported import Foundation

public final class ModelContainer: @unchecked Sendable {
    public init(for schema: Schema, configurations: [ModelConfiguration]) throws {}
    public init(for schema: Schema, configurations: ModelConfiguration...) throws {}
}

public struct Schema: Sendable {
    public init(_ models: [Any]) {}
}

public struct ModelConfiguration: Sendable {
    public init(_ name: String? = nil, schema: Schema? = nil, isStoredInMemoryOnly: Bool = false) {}
    public init(isStoredInMemoryOnly: Bool) {}
}
