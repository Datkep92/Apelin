import Foundation

/// Who builds the project, read from its `apelin-project.json`: Apelin's
/// build tool from the build description, or the project's own tools.
enum ProjectBuildSystem: Equatable {
    /// `buildStart` from the manifest's configurations and products.
    case apelin
    /// A workspace: `kind` is `workspace` or `buildSystem` is `external`. A
    /// workspace written before `buildSystem` existed has neither recipe nor
    /// field, so it is external too.
    case external

    static let manifestFile = "apelin-project.json"
    static let maxManifestBytes = 1 << 20

    /// Read again on every call, so a manifest the agent or the user edits
    /// counts from the next prompt. A manifest that is missing, too large or
    /// not JSON is Apelin's: the build tool then reports what is wrong.
    static func read(in root: ScopedRoot) -> ProjectBuildSystem {
        guard let path = try? root.resolveExisting(manifestFile),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path) else { return .apelin }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxManifestBytes + 1), data.count <= maxManifestBytes,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .apelin }
        if manifest["kind"] as? String == "workspace" || manifest["buildSystem"] as? String == "external" {
            return .external
        }
        return .apelin
    }

    /// What the build tool answers on a workspace, instead of the build
    /// worker's error about a description the workspace never had.
    static let externalBuildRefusal = "This workspace's build system is external: Apelin's build tool has no build description for it. Build it with the project's own tools through run_code (make, cmake, swift build, its scripts), and write how into AGENTS.md at the project root."
}
