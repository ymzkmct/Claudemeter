// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Claudemeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Claudemeter",
            path: "Sources/Claudemeter"
        ),
        .testTarget(
            name: "ClaudemeterTests",
            dependencies: ["Claudemeter"],
            path: "Tests/ClaudemeterTests"
        ),
    ]
)
