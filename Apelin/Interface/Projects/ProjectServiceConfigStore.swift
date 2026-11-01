import Foundation
import ApelinCore

/// Loads and saves per-project service configurations from the project
/// folder as `apelin-services.json`.
enum ProjectServiceConfigStore {
    static let fileName = "apelin-services.json"

    /// Load config for a project, or return empty if none exists.
    static func load(projectName: String) -> ProjectServiceConfig {
        guard let folder = DataFolder.app.project(named: projectName),
              let url = CanonicalPath.resolve(folder.appendingPathComponent(fileName).path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: url)),
              let config = try? JSONCoding.decode(ProjectServiceConfig.self, from: data)
        else { return .empty }
        return config
    }

    /// Save config for a project.
    static func save(_ config: ProjectServiceConfig, projectName: String) throws {
        guard let folder = DataFolder.app.project(named: projectName) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try DataFolder.app.makeLevels(to: folder)
        let url = folder.appendingPathComponent(fileName)
        let data = try JSONCoding.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
