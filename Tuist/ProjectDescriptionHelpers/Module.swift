import ProjectDescription

public let loomBundlePrefix = "com.loom"
public let loomDeploymentTargets: DeploymentTargets = .macOS("14.0")

public extension Target {
    /// Factory that stamps out a Loom module target with shared conventions,
    /// so each module in `Project.swift` stays a one-liner.
    static func module(
        name: String,
        product: Product = .framework,
        bundleIdSuffix: String? = nil,
        sources: ProjectDescription.SourceFilesList,
        resources: ProjectDescription.ResourceFileElements? = nil,
        infoPlist: InfoPlist = .default,
        entitlements: Entitlements? = nil,
        dependencies: [TargetDependency] = [],
        settings: Settings? = nil
    ) -> Target {
        .target(
            name: name,
            destinations: .macOS,
            product: product,
            bundleId: "\(loomBundlePrefix).\(bundleIdSuffix ?? name.lowercased())",
            deploymentTargets: loomDeploymentTargets,
            infoPlist: infoPlist,
            sources: sources,
            resources: resources,
            entitlements: entitlements,
            dependencies: dependencies,
            settings: settings
        )
    }
}
