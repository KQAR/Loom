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
        "NIOHTTPCompression": .framework,
        "NIOHTTP2": .framework,
        "NIOHPACK": .framework,
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
        // Keep NIO's C shim targets as STATIC frameworks. When a framework NIO
        // module (above) pulls a C target in, Tuist would otherwise build that C
        // target as a *dynamic* framework too — and a dynamic C-target framework's
        // generated "Copy Module Map" script phase forms a build-system cycle with
        // its Copy-Files phase ("Cycle inside CNIODarwin …"), which fails clean
        // builds (`tuist run`, CI). A static framework is linked at build time
        // (not embedded/copied), so there's no cycle — while still exposing its
        // module map by the framework product path (a plain `.staticLibrary`
        // instead fails to link: "library 'CNIOAtomics' not found"). Unlike the
        // Swift modules above, these are stateless C shims (syscall/atomics/parser
        // wrappers) with no global state, so statically linking a copy into each
        // consuming framework is harmless — it does NOT reintroduce the NIO "one
        // shared copy" crash, which is about stateful Swift types (event loops).
        "CNIODarwin": .staticFramework,
        "CNIOPosix": .staticFramework,
        "CNIOAtomics": .staticFramework,
        "CNIOSHA1": .staticFramework,
        "CNIOLLHTTP": .staticFramework,
        "CNIOExtrasZlib": .staticFramework,
        "CNIOBoringSSL": .staticFramework,
        "CNIOBoringSSLShims": .staticFramework,
    ]
)
#endif

let package = Package(
    name: "LoomDependencies",
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.17.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.72.0"),
        // M4: NIOHTTPCompression (upstream response decompression in the NIO client).
        .package(url: "https://github.com/apple/swift-nio-extras", from: "1.20.0"),
        // M4: HTTP/2 interception (ALPN h2 → demux streams, reuse the h1 capture path).
        .package(url: "https://github.com/apple/swift-nio-http2", from: "1.30.0"),
        // M2 HTTPS interception: TLS termination in the NIO pipeline + on-demand
        // X.509 CA/leaf generation. swift-certificates pulls swift-crypto + swift-asn1.
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.26.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.4.0"),
        // In-app auto-update (check + download + install), same engine as looper.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ]
)
