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
            resources: ["App/Resources/**"], // Assets.xcassets → AppIcon
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true, // agent app: no Dock icon, status bar only
                // Render in the pre-26 (macOS 14/15) system design rather than Liquid
                // Glass. Not a compatibility hedge — a deliberate look: DESIGN.md's
                // baseline is macOS 14 (§ Known Gaps: use `.bordered`/`.borderedProminent`,
                // not `.glass`), and every control here is drawn that way already. What
                // macOS 26 adds on top is *system* chrome Loom cannot opt out of per view
                // — the shared-glass toolbar capsule that stretches when a `.principal`
                // item is padded, and the `NSScrollPocket` band across the window top that
                // survives `titlebarAppearsTransparent` and `scrollEdgeEffectHidden` (both
                // dead ends are recorded in `MainView.body`). This key is the one lever
                // that removes them, so the window matches the spec instead of the spec
                // being rewritten around the OS.
                //
                // It is honored by AppKit on macOS, not just UIKit — measured on 26.5 with
                // one probe binary and two Info.plists: NSButton 37×24 → 47×32, NSTextField
                // height 24 → 21, titlebar 32 → 28pt. Loom's own metrics (sidebar 300,
                // LoomTheme spacing, the 7pt capture dot) are untouched by it.
                //
                // Expiry, and the reason this comment is long: Apple documents the key as
                // temporary and intends to drop it in the Xcode release after 26. When it
                // stops working the window gains the glass chrome back — that is a DESIGN.md
                // decision to re-make (adopt it deliberately, per-surface), not a build
                // regression to chase.
                "UIDesignRequiresCompatibility": true,
                "CFBundleDisplayName": "Loom",
                "CFBundleIconName": "AppIcon", // resolves to the asset-catalog icon set
                "CFBundleShortVersionString": "0.0.14", // marketing version
                "CFBundleVersion": "14",               // build number — Sparkle compares THIS, bump it every release
                // Sparkle auto-update. The feed is the signed appcast attached to
                // each GitHub release. We drive the once-a-day check ourselves
                // (silent probe → panel "Update" button), so leave Sparkle's own
                // scheduling off. SUPublicEDKey is the EdDSA public key from
                // `generate_keys`; the matching private key signs the appcast in CI
                // (secret SPARKLE_EDDSA_KEY). See "Release & Auto-Update" in AGENTS.md.
                "SUFeedURL": "https://github.com/KQAR/Loom/releases/latest/download/appcast.xml",
                "SUPublicEDKey": "HOQ0tDtw/nV9GXRIMUtzImgNssckFEj5fFLe2Lp0LDY=",
                "SUEnableAutomaticChecks": false,
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
                .target(name: "LoomProxyCore"),
                .target(name: "MCPServer"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "UpdaterClient"),
                .target(name: "LoomSharedModels"),
            ],
            settings: .settings(base: ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"])
        ),

        // MARK: Features (TCA) — M1 keeps a single AppFeature; split later.
        .module(
            name: "AppFeature",
            sources: ["Features/AppFeature/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "ProxyClient"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "UpdaterClient"),
                .target(name: "LoomSharedModels"),
            ]
        ),

        // MARK: Clients (TCA @DependencyClient wrappers over the engine)
        .module(
            name: "ProxyClient",
            sources: ["Clients/ProxyClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "LoomProxyCore"),
                .target(name: "LoomSharedModels"),
            ]
        ),

        // MARK: Auto-update client (TCA wrapper over Sparkle). Swift 5 language
        // mode for the same reason as the helper client: an Obj-C framework whose
        // delegate callbacks fight Swift 6 strict-concurrency isolation.
        .module(
            name: "UpdaterClient",
            sources: ["Clients/UpdaterClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .external(name: "Sparkle"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),

        // MARK: Engine (plain Swift, zero TCA)
        .module(
            name: "LoomProxyCore",
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
                .target(name: "LoomSharedModels"),
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
                .target(name: "LoomSharedModels"),
            ]
            // Swift 6 language mode (strict concurrency). Unlike LoomProxyCore this
            // module owns exactly one channel handler and no forwarding path, so the
            // NIO-vs-Sendable friction that keeps the engine on Swift 5 amounts to
            // three JSON-schema statics and one buffer copy — see the type comments
            // on `MCPTool` and `MCPToolExecutor.iso8601`.
        ),
        .module(
            name: "LoomSharedModels",
            sources: ["SharedModels/Sources/**"]
        ),

        // MARK: Privileged-helper contract (app ⇄ root daemon)
        //
        // Deliberately NOT part of LoomSharedModels. That module ships as a public
        // SPM product ("pure value types … a consumer that just wants to map Loom's
        // models"), and an embedder has no use for our XPC protocol, launchd label,
        // code-signing requirement or `networksetup` state — it is Loom-app
        // deployment detail, not domain model. Both sides of the contract (the
        // app-side client and the daemon) depend on this instead.
        .module(
            name: "LoomHelperProtocol",
            sources: ["HelperProtocol/Sources/**"]
        ),

        // MARK: Privileged-helper client (M2, scaffold — app-side surface over the
        // root helper: SMAppService lifecycle + XPC for system proxy & CA trust).
        .module(
            name: "PrivilegedHelperClient",
            sources: ["Clients/PrivilegedHelperClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "LoomSharedModels"),
                .target(name: "LoomHelperProtocol"),
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
                // The daemon needs only the contract, not the domain models.
                .target(name: "LoomHelperProtocol"),
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
                .target(name: "LoomProxyCore"),
                .target(name: "LoomSharedModels"),
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
                .target(name: "UpdaterClient"),
                .target(name: "LoomSharedModels"),
                .external(name: "ComposableArchitecture"),
                // Transitive through UpdaterClient; the test target must see the
                // module directly to load AppFeature's interface (@testable import).
                .external(name: "Sparkle"),
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
                .target(name: "LoomSharedModels"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),

        // MARK: SharedModels unit tests (FlowQuery predicates, URLHost parity,
        // mock-model decoding). These already ran under `swift test` via the root
        // Package.swift, but were absent from the Tuist graph — so 37 tests were
        // invisible to Xcode and to any xcodebuild-driven CI.
        .target(
            name: "SharedModelsTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.loom.sharedmodelstests",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: .default,
            sources: ["SharedModels/Tests/**"],
            dependencies: [
                .target(name: "LoomSharedModels"),
            ]
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
                .target(name: "LoomSharedModels"),
                .target(name: "LoomHelperProtocol"),
            ],
            settings: .settings(base: ["SWIFT_VERSION": "5.0"])
        ),
    ]
)
