// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Halo",
            path: "Sources/Halo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
