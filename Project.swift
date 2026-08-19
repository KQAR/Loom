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
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            // Every target in the graph — modules AND test bundles — is checked at
            // `complete`. The Swift 6 language mode implies it, so this is belt-and-
            // braces for the module targets; what it actually buys is that a target
            // which ever drops back to `SWIFT_VERSION = 5.0` still gets the diagnostics
            // as warnings rather than silently losing the checking.
            "SWIFT_STRICT_CONCURRENCY": "complete",
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
                // Regular app, not an agent: Loom shows in the Dock and the app
                // switcher. It was `LSUIElement: true` (status-bar only) — but the
                // main window is the working surface, opened at launch, and a
                // Dock-less app gives no way back to it once it's closed: no Dock
                // click, no ⌘-Tab, only the panel. The status-bar console stays the
                // primary surface (DESIGN/INTERACTION v3); the Dock icon is the
                // second way in, not a replacement. Closing the window does not
                // quit — `AppDelegate.applicationShouldHandleReopen` reopens it.
                "LSUIElement": false,
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
                "CFBundleShortVersionString": "0.0.29", // marketing version
                "CFBundleVersion": "28",               // build number — Sparkle compares THIS, bump it every release
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
            // **No entitlements file, deliberately.** Loom must not be sandboxed —
            // it binds a listening socket on 0.0.0.0 for device capture, shells out to
            // `networksetup`/`pfctl` for the system-proxy toggle, reads other processes
            // through libproc to attribute a flow to an app, registers a root
            // LaunchDaemon via SMAppService, installs CA trust through Authorization
            // Services, and writes the CA and both SQLite stores to
            // `~/Library/Application Support/com.loom` rather than a container. A
            // sandbox breaks every one of those.
            //
            // But **unsandboxed is the default**, so the `com.apple.security.app-sandbox:
            // false` this used to declare was an assertion of a default — and asserting
            // it cost something real. As `.dictionary` it was materialized into
            // `Derived/Entitlements/` and **rewritten on every `tuist generate`**:
            // byte-identical content, fresh mtime. Xcode's entitlements check is
            // mtime-based, so the next incremental build failed with "Entitlements file
            // was modified during the build" and kept failing until DerivedData was
            // deleted. Verified with a bare `touch` of that file and nothing else, and
            // verified gone here: `codesign -d --entitlements` on the built app shows no
            // `app-sandbox` key at all, which is the same unsandboxed state.
            //
            // So: if a real entitlement is ever needed, add it as `.file(path:)` with a
            // tracked file — never `.dictionary`. See AGENTS.md § Known Issues.
            entitlements: nil,
            scripts: [
                // Runs before the final CodeSign step, so the app's seal covers both
                // copied files — see the script's own header for why that ordering is
                // load-bearing.
                .post(
                    path: "Scripts/embed-helper.sh",
                    name: "Embed privileged helper",
                    inputPaths: ["$(BUILT_PRODUCTS_DIR)/com.loom.proxyhelper", "$(SRCROOT)/Helper/Daemon/com.loom.proxyhelper.plist"],
                    outputPaths: [
                        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/HelperTools/com.loom.proxyhelper",
                        "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Library/LaunchDaemons/com.loom.proxyhelper.plist",
                    ]
                ),
            ],
            dependencies: [
                .target(name: "AppFeature"),
                .target(name: "ProxyClient"),
                .target(name: "LoomProxyCore"),
                .target(name: "MCPServer"),
                .target(name: "PrivilegedHelperClient"),
                .target(name: "UpdaterClient"),
                .target(name: "LoomSharedModels"),
                // Build-order only — the script phase above does the embedding. The
                // app must not *link* an executable.
                .target(name: "loom-helper"),
            ],
            settings: .settings(base: ["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"])
        ),

        // MARK: Features (TCA) — M1 keeps a single AppFeature; split later.
        .module(
            name: "AppFeature",
            sources: ["Features/AppFeature/Sources/**"],
            // The design system's color sets (`LoomTheme.Palette`). They live with
            // the views rather than in the app's own catalog because the palette is
            // the design layer's, and because a framework-owned catalog resolves
            // through the generated asset symbols — a color that is renamed or
            // deleted then fails to compile instead of resolving to nothing at
            // runtime, which is the failure mode the custom SF Symbol already cost
            // this project once (CLAUDE.md § Known Issues).
            resources: ["Features/AppFeature/Resources/**"],
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

        // MARK: Auto-update client (TCA wrapper over Sparkle)
        .module(
            name: "UpdaterClient",
            sources: ["Clients/UpdaterClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .external(name: "Sparkle"),
            ]
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
            // Swift 6 language mode (strict concurrency). NOT with 6.2's
            // `SWIFT_APPROACHABLE_CONCURRENCY` — see Package.swift for why that flag is
            // off limits here: it changes the ABI of every `nonisolated async` function,
            // and this module is a public SPM product.
            settings: .settings(base: ["SWIFT_VERSION": "6.0"])
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

        // MARK: System-proxy client (drives the helper when installed, `networksetup`
        // + one osascript prompt when it isn't).
        .module(
            name: "PrivilegedHelperClient",
            sources: ["Clients/PrivilegedHelperClient/Sources/**"],
            dependencies: [
                .external(name: "ComposableArchitecture"),
                .target(name: "LoomSharedModels"),
                .target(name: "LoomHelperShared"),
            ]
        ),

        // MARK: The app↔helper contract — XPC protocol, service names, and the
        // system-proxy shell both ends run. Depended on by BOTH sides on purpose:
        // a second copy of that script is a second definition of what the toggle does.
        // **Static** on purpose. As a dynamic framework the daemon linked it by
        // `@rpath` and a command-line tool carries no rpath into the app bundle, so
        // dyld could not find it: the daemon died at launch every time, launchd
        // recorded `EX_CONFIG` and respawned it (179 times before this was caught),
        // and from the app's side the XPC call simply never answered — no reply, no
        // error, no process. Adding `@executable_path/../Frameworks` would also work,
        // but a root daemon that loads code out of the app bundle at runtime is a
        // worse shape than one that carries its own: static linking means the
        // privileged process has no third-party load paths at all.
        .module(
            name: "LoomHelperShared",
            product: .staticFramework,
            sources: ["Helper/Shared/Sources/**"]
        ),

        // MARK: The privileged helper itself — a root LaunchDaemon, embedded in the
        // app bundle and registered through `SMAppService`. Not a framework: launchd
        // executes it, and `BundleProgram` in the plist points at `Contents/MacOS/`.
        .module(
            name: "loom-helper",
            product: .commandLineTool,
            bundleIdSuffix: "proxyhelper",
            sources: ["Helper/Daemon/Sources/**"],
            // A command-line tool has no Info.plist *file*, so this one is embedded
            // into the binary (`CREATE_INFOPLIST_SECTION_IN_BINARY` below). It is not
            // decoration: without a `CFBundleIdentifier` to sign against, codesign
            // names the binary `loom-helper-<hash>` and the app's check on the daemon
            // (`identifier "com.loom.proxyhelper"`) can never pass — measured, and the
            // failure surfaces as "the helper is not reachable", which reads like a
            // missing daemon rather than a naming mismatch.
            infoPlist: .extendingDefault(with: [
                "CFBundleIdentifier": "com.loom.proxyhelper",
                "CFBundleName": "com.loom.proxyhelper",
                "CFBundlePackageType": "APPL",
            ]),
            dependencies: [
                .target(name: "LoomHelperShared"),
            ],
            // Xcode would otherwise name the binary `loom_helper` (it sanitizes the
            // target name, as it does for `loom-mcp`). The plist's `BundleProgram`
            // names the file on disk, and launchd's failure to find it is silent from
            // the app's side — `SMAppService` reports `notFound` with nothing about
            // which half is missing. Pin the name instead.
            // The product is named after the daemon's label, which is also what the
            // plist's `BundleProgram` points at — Xcode would otherwise sanitize the
            // target name to `loom_helper`. `PRODUCT_BUNDLE_IDENTIFIER` +
            // `CREATE_INFOPLIST_SECTION_IN_BINARY` give the binary a code-signing
            // identifier: without an Info.plist section a command-line tool signs as
            // `<name>-<hash>`, and the app's check on the daemon
            // (`identifier "com.loom.proxyhelper"`) could never pass.
            settings: .settings(base: [
                "PRODUCT_NAME": "com.loom.proxyhelper",
                "PRODUCT_BUNDLE_IDENTIFIER": "com.loom.proxyhelper",
                "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
            ])
        ),

        // MARK: stdio <-> HTTP bridge that AI clients (Claude/Cursor) launch
        .module(
            name: "loom-mcp",
            product: .commandLineTool,
            bundleIdSuffix: "mcp",
            sources: ["Bridge/Sources/**"]
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
            ]
            // Swift 6 language mode (inherited from the project base) — the test
            // bundles used to sit on 5.0 so a red test meant a real regression rather
            // than a migration artifact. That reason expired once the modules landed
            // on 6: the tests drive NIO channels and actors directly, which is exactly
            // the code strict concurrency has something to say about.
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
        // via a stub engine).
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
            ]
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
                .target(name: "LoomHelperShared"),
            ]
        ),
    ]
)
