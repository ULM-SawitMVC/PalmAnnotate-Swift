// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PalmCore", targets: ["PalmCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.21")
    ],
    targets: [
        .target(name: "PalmCore", dependencies: ["ZIPFoundation"]),
        .testTarget(name: "PalmCoreTests", dependencies: ["PalmCore"])
    ]
)
