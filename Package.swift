// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mdocker",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(name: "mdocker", dependencies: ["Yams"]),
        .testTarget(name: "mdockerTests", dependencies: ["mdocker"]),
    ]
)
