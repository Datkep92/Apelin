import Foundation

/// The skills every session has, one file each in `BuiltIn/`. They are
/// source, not bundle resources: a resource bundle's accessor would carry the
/// build machine's path into the binary.
///
/// What they say about the device was read from Apelin's own templates and
/// pipeline and from the sibling apps' sources and notes (Irisin's installer,
/// icli, Xrash, iGhostVT, Fila, LookInside's tweak) and roothide's developer
/// notes; a claim nobody has seen hold on a device stays out.
enum BuiltInSkills {
    static let all: [SkillDocument] = [
        tweakDevelopment,
        bootstrapPaths,
        tweakRuntime,
        preferenceBundle,
        projectDescription,
        externalBuild,
        packagingAndInstall,
        packageDependencies,
        crashTriage,
    ]
}
