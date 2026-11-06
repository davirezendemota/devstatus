// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevStatus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DevStatus", path: "Sources/DevStatus")
    ]
)
