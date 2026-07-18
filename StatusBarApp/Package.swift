// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentStatusBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentStatusBar",
            path: "Sources/AgentStatusBar"),
        .testTarget(
            name: "AgentStatusBarTests",
            dependencies: ["AgentStatusBar"],
            path: "Tests/AgentStatusBarTests"),
    ]
)
