import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "Loom",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
        ]
    ),
    targets: [
        // MARK: App shell (MenuBarExtra entry, wires live dependencies)
        .module(
            name: "Loom",
            product: .app,
            bundleIdSuffix: "app",
            sources: ["App/Sources/**"],
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true, // agent app: no Dock icon, status bar only
                "CFBundleDisplayName": "Loom",
                "CFBundleShortVersionString": "0.0.1", // marketing version
                "CFBundleVersion": "1",                // build number
                // A proxy must reach arbitrary upstreams, including plain HTTP;
                // without this, ATS blocks the app's own forwarding (502s).
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsArbitraryLoads": true,
                ]),
            ]),
            entitlements: .dictionary([
                // Allow the app to register/manage the privileged helper (M2, scaffold).
                "com.apple.security.app-sandbox": false,
            ]),
            dependencies: [
                .target(name: "AppFeature"),
                .target(name: "ProxyClient"),
                .target(name: "ProxyCore"),
                .target(name: "MCPServer"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "SharedModels"),
            ]
        ),

        // MARK: Features (TCA) — M1 keeps a single AppFeature; split later.
        .module(
            name: "AppFeature",
            sources: ["Features/AppFeature/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "ProxyClient"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "SharedModels"),
            ]
        ),

        // MARK: Clients (TCA @DependencyClient wrappers over the engine)
        .module(
            name: "ProxyClient",
            sources: ["Clients/ProxyClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "ProxyCore"),
                .target(name: "SharedModels"),
            ]
        ),

        // MARK: Engine (plain Swift, zero TCA)
        .module(
            name: "ProxyCore",
            sources: ["Engine/ProxyCore/Sources/**"],
            dependencies: [
                .external(name: "NIO"),
                .external(name: "NIOCore"),
                .external(name: "NIOPosix"),
                .external(name: "NIOHTTP1"),
                .external(name: "NIOHTTPCompression"), // M4: decompress upstream responses in the NIO client
                .external(name: "NIOHTTP2"),  // M4: HTTP/2 interception
                .external(name: "NIOTLS"),    // M4: ALPN negotiation handler
                .external(name: "NIOSSL"),   // M2: TLS termination for HTTPS interception
                .external(name: "X509"),     // M2: on-demand CA + leaf certificate minting
                .external(name: "Crypto"),
                .external(name: "SwiftASN1"),
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"]) // NIO channel model vs Swift 6 Sendable
        ),
        .module(
            name: "MCPServer",
            sources: ["Engine/MCPServer/Sources/**"],
            dependencies: [
                .external(name: "NIO"),
                .external(name: "NIOCore"),
                .external(name: "NIOPosix"),
                .external(name: "NIOHTTP1"),
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),
        .module(
            name: "SharedModels",
            sources: ["SharedModels/Sources/**"]
        ),

        // MARK: Privileged-helper client (M2, scaffold — app-side surface over the
        // root helper: SMAppService lifecycle + XPC for system proxy & CA trust).
        .module(
            name: "PrivilegedHelperClient",
            sources: ["Clients/PrivilegedHelperClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"]) // XPC + continuations vs Swift 6 Sendable
        ),

        // MARK: stdio <-> HTTP bridge that AI clients (Claude/Cursor) launch
        .module(
            name: "loom-mcp",
            product: .commandLineTool,
            bundleIdSuffix: "mcp",
            sources: ["Bridge/Sources/**"]
        ),

        // MARK: Privileged helper (M2, scaffold). Installs the CA into the
        // system trust store and toggles the system proxy. Not embedded in the
        // app bundle yet and unsigned here, so runtime registration is unverified.
        .module(
            name: "LoomHelper",
            product: .commandLineTool,
            bundleIdSuffix: "helper",
            sources: ["Engine/PrivilegedHelper/Sources/**"],
            dependencies: [
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"]) // XPC daemon: shared mutable state + locks
        ),

        // MARK: Engine unit + integration tests (proves decrypted HTTPS capture)
        .target(
            name: "ProxyCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.loom.proxycoretests",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: .default,
            sources: ["Engine/ProxyCore/Tests/**"],
            dependencies: [
                .target(name: "ProxyCore"),
                .target(name: "SharedModels"),
                .external(name: "NIOCore"),
                .external(name: "NIOPosix"),
                .external(name: "NIOHTTP1"),
                .external(name: "NIOSSL"),
                .external(name: "X509"),
                .external(name: "Crypto"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),

        // MARK: AppFeature reducer + pure-logic unit tests (TCA TestStore).
        // AppFeature is Swift 6, so NO SWIFT_VERSION override here.
        .target(
            name: "AppFeatureTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.loom.appfeaturetests",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: .default,
            sources: ["Features/AppFeature/Tests/**"],
            dependencies: [
                .target(name: "AppFeature"),
                .target(name: "ProxyClient"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "SharedModels"),
                .external(name: "ComposableArchitecture"),
            ]
        ),

        // MARK: MCP tool-executor tests (registry consistency + parse/dispatch,
        // via a stub engine). Swift 5 to match the MCPServer module.
        .target(
            name: "MCPServerTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.loom.mcpservertests",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: .default,
            sources: ["Engine/MCPServer/Tests/**"],
            dependencies: [
                .target(name: "MCPServer"),
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),

        // MARK: Privileged-client unit tests (pure logic: QUIC-block scripting)
        .target(
            name: "PrivilegedHelperClientTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.loom.privilegedhelperclienttests",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: .default,
            sources: ["Clients/PrivilegedHelperClient/Tests/**"],
            dependencies: [
                .target(name: "PrivilegedHelperClient"),
                .target(name: "SharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),
    ]
)
