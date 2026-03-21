// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ctxmv",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "ctxmv", targets: ["ctxmv"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),

        .package(url: "https://github.com/onevcat/Rainbow.git", from: "4.0.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.3"),
        .package(url: "https://github.com/Ryu0118/AgentSessions.git", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "ctxmv",
            dependencies: [
                "CTXMVCLI",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/ctxmv"
        ),
        .target(
            name: "CTXMVCLI",
            dependencies: [
                "CTXMVKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "CTXMVKit",
            dependencies: [
                .product(name: "AgentSessions", package: "AgentSessions"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Rainbow", package: "Rainbow"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ]
        ),
        .testTarget(
            name: "CTXMVKitTests",
            dependencies: ["CTXMVKit"]
        ),
    ]
)
