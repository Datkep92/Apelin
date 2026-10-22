import ApelinCore

/// Whether a project has a build description apelin-build can build and
/// package it from, read off its `apelin-project.json`. A workspace —
/// `kind: workspace`, or `buildSystem: external`, as the agent's
/// `ProjectBuildSystem` reads it — is built by its own tools, and a
/// manifest of any other kind without a `build` has no recipe; either way
/// there is nothing to distribute until the agent writes one.
enum ProjectBuildDescription {
    /// The kinds apelin-build builds; anything else is a workspace.
    private static let buildableKinds: Set<String> = ["app", "tweak", "cli", "preferences"]

    static func isPresent(in manifest: JSONValue) -> Bool {
        guard let kind = manifest["kind"]?.stringValue, buildableKinds.contains(kind),
              manifest["buildSystem"]?.stringValue != "external",
              case .object? = manifest["build"]
        else { return false }
        return true
    }
}
