// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ballast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ballast", targets: ["Ballast"]),
        .library(name: "BallastCore", targets: ["BallastCore"]),
    ],
    targets: [
        .target(name: "BallastCore"),
        .executableTarget(name: "Ballast", dependencies: ["BallastCore"]),
        .testTarget(name: "BallastCoreTests", dependencies: ["BallastCore"]),
    ]
)
