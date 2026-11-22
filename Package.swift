// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Mirage",
            path: "Sources/Mirage",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
