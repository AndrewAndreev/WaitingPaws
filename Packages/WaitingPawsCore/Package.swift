// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WaitingPawsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WaitingPawsCore", targets: ["WaitingPawsCore"])
    ],
    targets: [
        .target(name: "WaitingPawsCore"),
        .testTarget(name: "WaitingPawsCoreTests", dependencies: ["WaitingPawsCore"])
    ]
)
