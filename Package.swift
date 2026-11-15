// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PortBar",
            path: "Sources/PortBar"
        )
    ]
)
