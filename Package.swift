// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TskViewer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TskCore", targets: ["TskCore"]),
        .executable(name: "TskViewer", targets: ["TskViewer"])
    ],
    targets: [
        .target(name: "TskCore"),
        .executableTarget(name: "TskViewer", dependencies: ["TskCore"]),
        .testTarget(name: "TskCoreTests", dependencies: ["TskCore"], resources: [.copy("Fixtures")])
    ]
)
