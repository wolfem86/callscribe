// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [.macOS("14.2")],
    targets: [
        // Pure logic with no UI or audio-hardware dependencies, so it can be unit tested.
        .target(
            name: "CallScribeCore",
            path: "Sources/CallScribeCore"
        ),
        .executableTarget(
            name: "CallScribe",
            dependencies: ["CallScribeCore"],
            path: "Sources/CallScribe",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "CallScribeCoreTests",
            dependencies: ["CallScribeCore"],
            path: "Tests/CallScribeCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
