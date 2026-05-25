// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisApp",
    platforms: [.iOS(.v18)],
    targets: [
        .executableTarget(name: "JarvisApp", path: "Sources/JarvisApp")
    ]
)
