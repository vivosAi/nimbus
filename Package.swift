// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusRing",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, unit-testable logic: coordinate math, palettes, the flare curve,
        // preference storage, and the shared GPU uniform layout.
        .target(
            name: "FocusRingKit",
            path: "Sources/FocusRingKit"
        ),
        // AppKit/Metal shell. Not unit-tested; verified by hand per milestone.
        .executableTarget(
            name: "FocusRing",
            dependencies: ["FocusRingKit"],
            path: "Sources/FocusRing",
            // Compiled at runtime by Metal, copied into the bundle by the
            // Makefile — SPM should leave it alone.
            exclude: ["Render/Shaders.metal"]
        ),
        .testTarget(
            name: "FocusRingTests",
            dependencies: ["FocusRingKit"],
            path: "Tests/FocusRingTests"
        ),
    ]
)
