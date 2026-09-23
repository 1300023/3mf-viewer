// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThreeMFViewer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ThreeMFViewer", targets: ["ThreeMFViewer"]),
        .executable(name: "ThreeMFQuickLook", targets: ["ThreeMFQuickLook"]),
        .executable(name: "ThreeMFThumbnail", targets: ["ThreeMFThumbnail"]),
        .library(name: "ThreeMFKit", targets: ["ThreeMFKit"]),
    ],
    targets: [
        // 3MF parsing (ZIP + XML + slicer metadata). Foundation only, no third-party dependencies.
        .target(
            name: "ThreeMFKit",
            path: "Sources/ThreeMFKit"
        ),
        // SceneKit scene building and off-screen rendering, shared by the app and the extensions.
        .target(
            name: "ThreeMFRendering",
            dependencies: ["ThreeMFKit"],
            path: "Sources/ThreeMFRendering"
        ),
        // The macOS app (SwiftUI).
        .executableTarget(
            name: "ThreeMFViewer",
            dependencies: ["ThreeMFKit", "ThreeMFRendering"],
            path: "Sources/ThreeMFViewer"
        ),
        // Quick Look preview extension (space bar in Finder). Packaged as an .appex by scripts/build-app.sh.
        .executableTarget(
            name: "ThreeMFQuickLook",
            dependencies: ["ThreeMFKit", "ThreeMFRendering"],
            path: "Sources/Extensions/QuickLookPreview"
        ),
        // Quick Look thumbnail extension (file icons in Finder).
        .executableTarget(
            name: "ThreeMFThumbnail",
            dependencies: ["ThreeMFKit", "ThreeMFRendering"],
            path: "Sources/Extensions/QuickLookThumbnail"
        ),
        .testTarget(
            name: "ThreeMFKitTests",
            dependencies: ["ThreeMFKit"],
            path: "Tests/ThreeMFKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
