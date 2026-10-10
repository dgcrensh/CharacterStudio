// swift-tools-version: 6.0
import PackageDescription

// CharacterCore is the UI-free geometry and input core shared by the app.
// It builds and tests on macOS and Linux with `swift test`.
let package = Package(
    name: "CharacterCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CharacterCore", targets: ["CharacterCore"]),
    ],
    targets: [
        .target(name: "CharacterCore"),
        .testTarget(name: "CharacterCoreTests", dependencies: ["CharacterCore"]),
    ]
)
