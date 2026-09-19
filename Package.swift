// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Tix", platforms: [.macOS(.v14)],
    products: [.library(name: "TixCore", targets: ["TixCore"]), .executable(name: "Tix", targets: ["TixApp"]), .executable(name: "tix-mcp", targets: ["TixMCP"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "TixCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "TixApp", dependencies: ["TixCore"]),
        .executableTarget(name: "TixMCP", dependencies: ["TixCore", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "TixCoreTests", dependencies: ["TixCore"])
    ]
)
