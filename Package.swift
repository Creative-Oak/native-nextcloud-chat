// swift-tools-version: 6.1
import PackageDescription

// The macOS app target in Kvidr.xcodeproj compiles Sources/TalkCore directly
// (see docs/ARCHITECTURE.md § The one-module trick), so nothing in this repository
// ever writes `import TalkCore`. This package exists so the whole non-UI application
// can be built and tested from the command line.
let package = Package(
    name: "Kvidr",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TalkCore", targets: ["TalkCore"])
    ],
    targets: [
        .target(
            name: "TalkCore",
            path: "Sources/TalkCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TalkCoreTests",
            dependencies: ["TalkCore"],
            path: "Tests/TalkCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
