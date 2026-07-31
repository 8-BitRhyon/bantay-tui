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
    targets: [
        .executableTarget(
            name: "BantayTUI",
            path: "Sources/BantayTUI"
        ),
        .testTarget(
            name: "BantayTUILogicTests",
            dependencies: ["BantayTUI"],
            path: "Tests/BantayTUILogicTests"
        )
    ]
)
