// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SomarSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "SomarSDK", targets: ["SomarSDK"])
    ],
    targets: [
        .target(name: "SomarSDK"),
        .testTarget(name: "SomarSDKTests", dependencies: ["SomarSDK"])
    ]
)
