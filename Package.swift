// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimaiSwift",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "SimaiSwift", targets: ["SimaiSwift"])],
    targets: [
        .target(name: "SimaiSwift"),
        .testTarget(name: "SimaiSwiftTests", dependencies: ["SimaiSwift"])
    ],
    swiftLanguageVersions: [.v5]
)
