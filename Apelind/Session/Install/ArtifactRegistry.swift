import ApelinCore
import ApelinProtocol
import Foundation

/// The packages builds produced, as the build worker itself reported them.
///
/// The host records every `artifact` event an `apelin-build` emits on a
/// build task it owns — never one from the agent, the app or a project file —
/// so `installPackage{artifactID}` resolves to the file, digest, package and
/// project the build said, and the packaging digest the approval binds to.
/// Kept in `<state>/artifacts.json`, the newest `maximumCount`.
///
/// The event's payload is a `BuildArtifact` (`artifactID`, `digest`,
/// `packageID`, `version`) plus what the host needs to find and judge it:
/// `path` — the `.deb`, absolute, inside `~/Documents/wiki.qaq.apelin/` —,
/// `projectID` and `packagingDigest` (`sha256:…`, the packaging description
/// the deb was made from).
actor ArtifactRegistry {
    struct Artifact: Codable, Equatable, Sendable {
        var artifactID: String
        var path: String
        /// Lowercase hex SHA-256 of the deb.
        var digest: String
        var packageID: String?
        var version: String?
        var projectID: String?
        var buildID: String?
        var packagingDigest: String?
        var recordedAt: Date
    }

    static let maximumCount = 256

    private let file: URL
    private var artifacts: [Artifact] = []
    private var loaded = false

    init(file: URL) {
        self.file = file
    }

    /// Records an `artifact` event's payload from the build task `buildID`.
    /// Answers nil (and records nothing) for a payload without the fields
    /// the host needs.
    @discardableResult
    func record(event payload: JSONValue?, buildID: TaskID) -> Artifact? {
        loadIfNeeded()
        guard let payload,
              let artifactID = payload["artifactID"]?.stringValue, Self.validID(artifactID),
              let path = payload["path"]?.stringValue, path.hasPrefix("/"), !CanonicalPath.containsNUL(path),
              let digest = payload["digest"]?.stringValue.flatMap(InstallDigest.normalized)
        else { return nil }
        let artifact = Artifact(
            artifactID: artifactID,
            path: path,
            digest: digest,
            packageID: payload["packageID"]?.stringValue,
            version: payload["version"]?.stringValue,
            projectID: payload["projectID"]?.stringValue,
            buildID: buildID.rawValue,
            packagingDigest: payload["packagingDigest"]?.stringValue,
            recordedAt: Date(),
        )
        artifacts.removeAll { $0.artifactID == artifactID }
        artifacts.append(artifact)
        artifacts = Array(artifacts.suffix(Self.maximumCount))
        save()
        return artifact
    }

    /// Drops what a build reported before the host restarted: the resumed
    /// build cleans its folder, so that package is gone.
    func forget(buildID: TaskID) {
        loadIfNeeded()
        let count = artifacts.count
        artifacts.removeAll { $0.buildID == buildID.rawValue }
        if artifacts.count != count {
            save()
        }
    }

    func artifact(_ id: String) -> Artifact? {
        loadIfNeeded()
        return artifacts.last { $0.artifactID == id }
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix("file:") && !CanonicalPath.containsNUL(id) && !id.contains("/")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: file), let list = try? JSONCoding.decode([Artifact].self, from: data) {
            artifacts = list
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try? JSONCoding.encode(artifacts).write(to: file, options: .atomic)
    }
}

/// The digest irisind takes: 64 lowercase hex digits.
enum InstallDigest {
    /// Accepts `sha256:<hex>` or bare hex, any case; nil for anything else.
    static func normalized(_ digest: String) -> String? {
        let hex = (digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest).lowercased()
        guard hex.count == 64, hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
            return nil
        }
        return hex
    }
}
