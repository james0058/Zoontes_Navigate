// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EasyConnKit",
    platforms: [.iOS(.v13), .macOS(.v13)],
    products: [.library(name: "EasyConnKit", targets: ["EasyConnKit"])],
    targets: [
        .target(name: "EasyConnKit"),
        .testTarget(name: "EasyConnKitTests", dependencies: ["EasyConnKit"], resources: [.copy("Fixtures")]),
    ]
)
