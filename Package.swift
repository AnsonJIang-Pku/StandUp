// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "StandUpCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "StandUpCore", targets: ["StandUpCore"])],
    targets: [
        .target(name: "StandUpCore"),
        // Compile the existing app model for swift test without launching the menu-bar app.
        .target(name: "StandUpAppTestSupport", dependencies: ["StandUpCore"], path: "App",
                exclude: ["AppDelegate.swift", "Assets.xcassets", "Info.plist", "Resources", "StandUpApp.swift", "Views"],
                sources: ["AppModel.swift", "Services"]),
        .testTarget(name: "StandUpCoreTests", dependencies: ["StandUpCore", "StandUpAppTestSupport"])
    ]
)
