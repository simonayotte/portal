// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Portal",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(name: "Portal"),
        .testTarget(name: "PortalTests", dependencies: ["Portal"])
    ]
)
