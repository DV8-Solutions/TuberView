// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "TuberCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "TuberCore", targets: ["TuberCore"]),
    ],
    targets: [
        .target(name: "TuberCore"),
        .testTarget(name: "TuberCoreTests", dependencies: ["TuberCore"]),
    ]
)
