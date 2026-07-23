// swift-tools-version: 6.0
import PackageDescription

// SPM manifest that exposes Loom's reusable capture engine as a library, so
// other host tools (e.g. Reticle) can embed the proxy without pulling in the
// TCA UI, the MenuBar app, or the MCP/privileged-helper surface.
//
// This coexists with the Tuist project (Project.swift + Tuist/Package.swift):
//   - `tuist generate` still builds the full app from Project.swift.
//   - `swift build` / an external SPM consumer uses THIS manifest.
// Only two products are published — the pure-value models and the engine.
// Everything under App/, Features/, Clients/, Bridge/, Engine/MCPServer,
// Engine/PrivilegedHelper stays out of the package on purpose.
//
// Dependency version ranges are chosen to include the pins a consumer like
// Reticle already resolves (swift-nio 2.101.x, nio-ssl 2.37.x, certificates
// 1.19.x, crypto 4.5.x, asn1 1.7.x), so both projects share one solution.
let package = Package(
    name: "Loom",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // Pure value types (Flow, CapturedRequest/Response, HeaderPair, rules,
        // HAR, …). Foundation-only, no NIO — a consumer that just wants to map
        // Loom's models can depend on this alone.
        .library(name: "LoomSharedModels", targets: ["SharedModels"]),
        // The capture/forward engine: SwiftNIO proxy, HTTPS MITM, on-demand CA,
        // traffic rules, replay. Depends on SharedModels.
        .library(name: "LoomProxyCore", targets: ["ProxyCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.72.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.4.0"),
        // ProxyCore imports Crypto + SwiftASN1 directly (CertificateAuthority).
        // Crypto range spans 3.x–4.x so it can co-resolve with a consumer pinned
        // to 4.5.x while still building standalone.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SharedModels",
            path: "SharedModels/Sources"
        ),
        .target(
            name: "ProxyCore",
            dependencies: [
                "SharedModels",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOHTTPCompression", package: "swift-nio-extras"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ],
            path: "Engine/ProxyCore/Sources",
            // ProxyCore builds in Swift 5 language mode (the NIO channel model
            // predates Swift 6 Sendable enforcement) — matches Project.swift.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Pure-model tests runnable via `swift test` (no Tuist/NIO needed), so the
        // reusable library surface is verifiable standalone. App/engine tests stay
        // in the Tuist test targets.
        .testTarget(
            name: "SharedModelsTests",
            dependencies: ["SharedModels"],
            path: "SharedModels/Tests"
        ),
    ]
)
