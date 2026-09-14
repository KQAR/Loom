// swift-tools-version: 6.0
import PackageDescription

// Standalone on purpose: NOT part of the app graph (Project.swift) or the library
// graph (the root Package.swift). It depends on SwiftNIO only, so it proves the
// serialization failure it hunts belongs to NIOHTTP2 and not to Loom. See README.md.
//
// The http2 pin is exact because the version is part of the evidence.
let package = Package(
    name: "h2-frame-size-repro",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.72.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", exact: "1.44.0"),
    ],
    targets: [
        .executableTarget(
            name: "h2-frame-size",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            path: "Sources/h2-frame-size"
        ),
    ]
)
