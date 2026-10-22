import ApelinCore
import ApelinProtocol
import Foundation

@main struct Tests {
    static func main() {
        let source = SDKSourceStatus(name: "Test", url: "https://example.com/sdks", enabled: true, branches: ["sdk/iPhoneOS27.1", "sdk/iPhoneOS18.5", "sdk/iPhoneOS17.4", "sdk/iPhoneOS27.0", "sdk/iPhoneOSfoo"])
        let sdks = SDKListResponse(sources: [source])
        let c = ToolchainCatalogProduct(productID: "c", version: "28.0", size: 1, newestSDK: "27", supportsSwift: false)
        let swift = ToolchainCatalogProduct(productID: "swift", version: "27.0", size: 1, newestSDK: "27", supportsSwift: true, compatibility: .init(recommendedSDK: "27.0", recommendedSwiftSDK: "27.0"))
        let refused = ToolchainCatalogProduct(productID: "refused", version: "99.0", size: 1, unsupportedReason: "No host support", newestSDK: "27", supportsSwift: true)
        let unknown = ToolchainCatalogProduct(productID: "unknown", version: "unknown", size: 1, supportsSwift: true)
        let resolve = WelcomeEnvironmentRecommendation.resolve(catalog: [refused, c, swift, unknown], status: .init(), sdks: sdks)
        precondition(resolve?.toolchain.productID == "swift", "Supported Swift pair preferred over C-only newer release")
        precondition(resolve?.sdk.version == "27.0", "Reviewed pairing preferred to unverified point update")
        precondition(resolve?.sdk.installed == false)
        precondition(WelcomeEnvironmentRecommendation.resolve(catalog: [refused], status: .init(), sdks: sdks) == nil)
        precondition(WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(), sdks: .init(sources: [.init(name: "Old", url: "https://example.com", enabled: true, branches: ["sdk/iPhoneOS18.5"])])) == nil, "Swift requires matching SDK major")
        let old = ToolchainCatalogProduct(productID: "old", version: "15.3", size: 1, newestSDK: "17.4", supportsSwift: false)
        let fallback = WelcomeEnvironmentRecommendation.resolve(catalog: [old], status: .init(), sdks: sdks)
        precondition(fallback?.sdk.version == "17.4", "SDK limit respected")
        let healthy = ToolchainRecord(id: "installed", version: "27.0", components: [.init(kind: .c, selfCheckPassed: true), .init(kind: .swift, selfCheckPassed: true)], origin: "swift https://example.com")
        let installedSDK = SDKRecord(id: "sdk", canonicalName: "iPhoneOS27.0", version: "27.0", path: "/fixture")
        let installed = WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(toolchains: [healthy]), sdks: .init(sdks: [installedSDK], sources: [source]))
        precondition(installed?.isInstalled == true)
        var failed = healthy
        failed.components = [.init(kind: .c, selfCheckPassed: false), .init(kind: .swift, selfCheckPassed: true)]
        let unhealthy = WelcomeEnvironmentRecommendation.resolve(catalog: [swift], status: .init(toolchains: [failed]), sdks: .init(sdks: [installedSDK]))
        precondition(unhealthy?.isInstalled == false, "Failed installation never shown ready")
        for _ in 0 ..< 100 {
            let draft = ProjectCreationDraft()
            precondition(draft.isValid && ProjectName.validate(draft.name) == nil)
            precondition(draft.automaticallyName)
        }
        var draft = ProjectCreationDraft()
        let original = draft.name
        draft.avoidExisting([original.lowercased()])
        precondition(draft.name.caseInsensitiveCompare(original) != .orderedSame)
        draft.edit("My Project")
        draft.avoidExisting(["My Project"])
        precondition(draft.name == "My Project" && !draft.automaticallyName, "User name is never replaced")
        draft.edit(original)
        precondition(!draft.automaticallyName, "Retyping the fruit is still a user choice")
        draft.edit("../unsafe")
        precondition(!draft.isValid)
        draft.edit("  Good Name  ")
        precondition(draft.isValid && draft.trimmedName == "Good Name")
        print("ok: onboarding pairing and project naming behavior")

        // Distribute… and the distribution page's targets need a build
        // description apelin-build can package.
        let build: JSONValue = .object(["steps": .array([.object(["type": .string("compile")])])])
        let tweak: JSONValue = .object(["projectID": .string("p"), "kind": .string("tweak"), "build": build])
        precondition(ProjectBuildDescription.isPresent(in: tweak), "A template project has one")
        for kind in ["app", "cli", "preferences"] {
            precondition(ProjectBuildDescription.isPresent(in: .object(["kind": .string(kind), "build": build])))
        }
        let workspace: JSONValue = .object([
            "projectID": .string("w"), "kind": .string("workspace"), "buildSystem": .string("external"),
        ])
        precondition(!ProjectBuildDescription.isPresent(in: workspace), "An empty workspace has none")
        precondition(!ProjectBuildDescription.isPresent(in: .object(["kind": .string("workspace")])),
                     "A workspace from before buildSystem has none")
        precondition(!ProjectBuildDescription.isPresent(in: .object([
            "kind": .string("workspace"), "build": build,
        ])), "A workspace is built by its own tools, whatever it holds")
        precondition(!ProjectBuildDescription.isPresent(in: .object([
            "kind": .string("tweak"), "buildSystem": .string("external"), "build": build,
        ])), "An external build system is not apelin-build's")
        precondition(!ProjectBuildDescription.isPresent(in: .object(["kind": .string("tweak")])),
                     "A manifest without a build has nothing to build")
        precondition(!ProjectBuildDescription.isPresent(in: .object(["kind": .string("tweak"), "build": .null])))
        precondition(!ProjectBuildDescription.isPresent(in: .object(["build": build])), "No kind, no build")
        precondition(!ProjectBuildDescription.isPresent(in: .array([])))
        print("ok: distribution needs a build description")
    }
}
