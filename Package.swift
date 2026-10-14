// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TheExplorer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "TheExplorer",
            path: "Sources/TheExplorer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
