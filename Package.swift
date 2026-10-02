// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIDM",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "AIDM",
            dependencies: ["Yams"],
            path: "Sources/AIDM",
            exclude: [],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
