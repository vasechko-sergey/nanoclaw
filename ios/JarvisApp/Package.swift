// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JarvisApp",
    platforms: [.iOS(.v16)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .executableTarget(
            name: "JarvisApp",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/JarvisApp"
        )
    ]
)
