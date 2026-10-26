// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PaneLink",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CGVirtualDisplayBridge", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(
            name: "PaneLink",
            dependencies: ["CGVirtualDisplayBridge"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"), .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"), .linkedFramework("Network"), .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
