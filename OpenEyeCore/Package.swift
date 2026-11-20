// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenEyeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "OpenEyeCore", targets: ["OpenEyeCore"])],
    targets: [
        .target(name: "OpenEyeCore"),
        .testTarget(name: "OpenEyeCoreTests", dependencies: ["OpenEyeCore"]),
    ]
)
