// swift-tools-version:5.9
import PackageDescription

// Test harness for the Foundation-only core of the client. The app itself is
// built by Moonlight.xcodeproj; this package exists so `swift test` can run the
// pure-logic units in CI without an Xcode test target.
let package = Package(
    name: "MoonlightCore",
    platforms: [.macOS("15.0")],
    targets: [
        .target(
            name: "MoonlightCore",
            path: "Limelight/Core",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MoonlightCoreTests",
            dependencies: ["MoonlightCore"],
            path: "Tests/MoonlightCoreTests"
        ),
    ]
)
