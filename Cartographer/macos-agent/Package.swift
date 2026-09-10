// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CartographerAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CartographerAgent",
            path: "Sources/CartographerAgent"
        )
    ]
)
