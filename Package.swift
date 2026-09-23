// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThreeMFViewer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ThreeMFViewer", targets: ["ThreeMFViewer"]),
        .library(name: "ThreeMFKit", targets: ["ThreeMFKit"]),
    ],
    targets: [
        // Platform-independent 3MF parsing (ZIP + XML + slicer metadata). No third-party dependencies.
        .target(
            name: "ThreeMFKit",
            path: "Sources/ThreeMFKit"
        ),
        // The macOS app (SwiftUI + SceneKit).
        .executableTarget(
            name: "ThreeMFViewer",
            dependencies: ["ThreeMFKit"],
            path: "Sources/ThreeMFViewer"
        ),
        .testTarget(
            name: "ThreeMFKitTests",
            dependencies: ["ThreeMFKit"],
            path: "Tests/ThreeMFKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
