// swift-tools-version: 6.0
import PackageDescription

// Standalone on purpose: this package is NOT part of the app graph (Project.swift) or
// of the library graph (the root Package.swift). It depends on SwiftNIO only, so it
// proves the stall it hunts belongs to NIOHTTP2 and not to Loom. See README.md.
//
// Package.resolved is committed here (the root .gitignore only ignores the root one)
// because the exact NIO / NIOHTTP2 versions are part of the evidence.
let package = Package(
    name: "h2-stall-repro",
    // macOS 15 for `Synchronization.Mutex`, matching the app graph. The old .v14 was
    // inherited from before Loom's own floor rose in 0.0.16, not chosen — and the
    // harness below mirrors `RequestBodyBridge.Delegate`, which is a `Mutex` now, so
    // staying on `NSLock` here was drift from the very thing this package reproduces.
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.72.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.30.0"),
    ],
    targets: [
        // Deterministic model: does NOT reproduce, which is itself the finding.
        .executableTarget(
            name: "h2-embedded",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Real sockets: reproduces, ~1 % of runs under CPU contention.
        .executableTarget(
            name: "h2-sockets",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
