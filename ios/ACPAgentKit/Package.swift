// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ACPAgentKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "ACPAgentCore", targets: ["ACPAgentCore"]),
    ],
    targets: [
        .target(name: "ACPAgentCore"),
        .testTarget(name: "ACPAgentCoreTests", dependencies: ["ACPAgentCore"])
    ]
)
