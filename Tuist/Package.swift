// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    // Force swift-nio products to dynamic frameworks so there is exactly ONE copy
    // shared by ProxyCore and MCPServer. Statically linking NIO into both embeds
    // duplicate copies of its classes/event loops, which trips NIO's
    // "precondition in event loop" assertion at runtime (mysterious crashes).
    productTypes: [
        "ComposableArchitecture": .framework,
        "NIO": .framework,
        "NIOCore": .framework,
        "NIOPosix": .framework,
        "NIOHTTP1": .framework,
        "NIOConcurrencyHelpers": .framework,
        "NIOEmbedded": .framework,
        "NIOTLS": .framework,
        "NIOFoundationCompat": .framework,
        // NIO's transitive deps must be shared too, else their types (e.g.
        // ManagedAtomic) are duplicated inside the dynamic NIO frameworks and crash.
        "Atomics": .framework,
        "DequeModule": .framework,
        "_NIOBase64": .framework,
        "_NIODataStructures": .framework,
    ]
)
#endif

let package = Package(
    name: "LoomDependencies",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.72.0"),
        // M2 HTTPS interception: TLS termination in the NIO pipeline + on-demand
        // X.509 CA/leaf generation. swift-certificates pulls swift-crypto + swift-asn1.
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.4.0"),
    ]
)
