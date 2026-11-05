// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MCStackr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MCStackr",
            path: "Sources/MCStackr"
        )
    ]
)
