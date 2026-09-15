// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nimbus",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, unit-testable logic: coordinate math, palettes, the flare curve,
        // preference storage, and the shared GPU uniform layout.
        .target(
            name: "NimbusKit",
            path: "Sources/NimbusKit"
        ),
        // AppKit/Metal shell. Not unit-tested; verified by hand.
        .executableTarget(
            name: "Nimbus",
            dependencies: ["NimbusKit"],
            path: "Sources/Nimbus",
            // Compiled at runtime by Metal, copied into the bundle by the
            // Makefile — SPM should leave it alone.
            exclude: ["Render/Shaders.metal"]
        ),
        .testTarget(
            name: "NimbusTests",
            dependencies: ["NimbusKit"],
            path: "Tests/NimbusTests"
        ),
    ]
)
