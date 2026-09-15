// Stand-in for PhotosUI, and for the CoreTransferable surface it re-exports: only what the
// app uses. See run.sh.
//
// `Transferable` and friends really live in CoreTransferable, which both PhotosUI and
// SwiftUI re-export. The app reaches them through `import PhotosUI`, so they are declared
// here rather than in a module of their own — one fewer stub to build, and it matches how
// the app sees them.
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The file a transfer handed over, in the temporary place the system put it.
public struct ReceivedTransferredFile: Sendable {
    public let file: URL
    public let isOriginalFile: Bool

    public init(file: URL, isOriginalFile: Bool = false) {
        self.file = file
        self.isOriginalFile = isOriginalFile
    }
}

public protocol TransferRepresentation: Sendable {
    associatedtype Item
}

public protocol Transferable {
    associatedtype Representation: TransferRepresentation
    static var transferRepresentation: Representation { get }
}

/// The real initializer takes a `shouldAttemptToOpenInPlace` too; the app doesn't pass it,
/// so it is a defaulted parameter here for the same call sites to keep compiling.
public struct FileRepresentation<Item>: TransferRepresentation, @unchecked Sendable {
    public init(
        importedContentType: UTType,
        shouldAttemptToOpenInPlace: Bool = false,
        importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item
    ) {}
}

/// What the picker hands back. `Equatable` because the app watches the selection with
/// `onChange(of:)`, which requires it.
public struct PhotosPickerItem: Equatable, Hashable, Sendable {
    public init() {}

    public func loadTransferable<T: Transferable>(type: T.Type) async throws -> T? { nil }
}

public struct PHPickerFilter: Sendable {
    public static let images = PHPickerFilter()
    public static let videos = PHPickerFilter()
    public static func any(of subfilters: [PHPickerFilter]) -> PHPickerFilter { PHPickerFilter() }
}

extension View {
    public func photosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<[PhotosPickerItem]>,
        maxSelectionCount: Int? = nil,
        matching filter: PHPickerFilter? = nil
    ) -> StubView { StubView() }
}
