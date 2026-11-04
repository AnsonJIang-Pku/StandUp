// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "StandUpCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "StandUpCore", targets: ["StandUpCore"])],
    targets: [
        .target(name: "StandUpCore"),
        .testTarget(name: "StandUpCoreTests", dependencies: ["StandUpCore"])
    ]
)
