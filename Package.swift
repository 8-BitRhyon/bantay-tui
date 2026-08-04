// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BantayTUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "bantay", targets: ["BantayTUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"),
    ],
    targets: [
        .executableTarget(
            name: "BantayTUI",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/BantayTUI"
        ),
        .testTarget(
            name: "BantayTUILogicTests",
            dependencies: ["BantayTUI"],
            path: "Tests/BantayTUILogicTests"
        )
    ]
)
