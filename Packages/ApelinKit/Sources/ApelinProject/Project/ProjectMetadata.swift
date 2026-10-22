import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Display metadata lives in the real manifest; folder and project identities
/// do not change. Build and packaging digests deliberately exclude these fields.
public enum ProjectMetadata {
    private static let lock = NSLock()

    public static func initial(_ data: Data, name: String, automaticallyName: Bool) throws -> Data {
        guard automaticallyName else { return data }
        guard case var .object(document) = try StrictJSON.parse(data),
              var text = String(data: data, encoding: .utf8), let opening = text.firstIndex(of: "{")
        else {
            throw ApelinError(.badRequest, "The project manifest is not an object.")
        }
        if document["displayName"] != nil || document["autoName"] != nil {
            document["displayName"] = .string(name)
            document["autoName"] = .bool(true)
            return Data((JSONDocument.object(document).description + "\n").utf8)
        }
        // Preserve template formatting and every unrelated byte. Existing
        // templates have neither optional field, so only two members are added.
        text.insert(
            contentsOf: "\n  \"displayName\": " + CanonicalJSON.quote(name) + ",\n  \"autoName\": true,",
            at: text.index(after: opening),
        )
        return Data(text.utf8)
    }

    public static func rename(_ request: ProjectRenameRequest, in folder: DataFolder) throws -> ProjectRenameResponse {
        guard ProjectDisplayName.isValid(request.displayName) else {
            throw ApelinError(
                .badRequest,
                "Use a project name of 1–\(ProjectDisplayName.maximumLength) characters on one line, without leading or trailing spaces.",
            )
        }
        lock.lock()
        defer { lock.unlock() }
        let located = try? ProjectStore(dataFolder: folder).root(of: request.projectID)
        guard let candidate = located?.root ?? folder.project(named: request.projectID),
              let projects = CanonicalPath.resolve(folder.projects.path),
              let root = CanonicalPath.resolve(candidate.path),
              CanonicalPath.isCanonical(root, inside: projects),
              CanonicalPath.components(root).count == CanonicalPath.components(projects).count + 1
        else {
            throw ApelinError(.notFound, "The project folder is no longer available.")
        }
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(directory) }
        let descriptor = openat(directory, ProjectStore.projectFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var identity = stat()
        guard fstat(descriptor, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG,
              identity.st_size <= 8 * 1024 * 1024
        else {
            throw ApelinError(.badRequest, "The project manifest is not a regular supported file.")
        }
        let original = try handle.readToEnd() ?? Data()
        guard case var .object(document) = try StrictJSON.parse(original),
              let projectID = document["projectID"]?.stringValue
        else {
            throw ApelinError(.badRequest, "The project manifest has no identity.")
        }
        let current = document["displayName"]?.stringValue ?? candidate.lastPathComponent
        if request.onlyIfAutomatic, document["autoName"]?.boolValue != true || current != candidate.lastPathComponent {
            return ProjectRenameResponse(projectID: projectID, displayName: current, changed: false)
        }
        document["displayName"] = .string(request.displayName)
        document["autoName"] = .bool(false)
        let data = Data((JSONDocument.object(document).description + "\n").utf8)
        let temporary = ".apelin-metadata-" + UUID().uuidString
        let output = openat(
            directory,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            identity.st_mode & 0o777,
        )
        guard output >= 0 else { throw POSIXError(.EIO) }
        defer { close(output); unlinkat(directory, temporary, 0) }
        guard fchmod(output, identity.st_mode & 0o777) == 0 else { throw POSIXError(.EIO) }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        try writer.write(contentsOf: data)
        guard fsync(output) == 0 else { throw POSIXError(.EIO) }
        // Refuse a concurrent manifest replacement or in-place edit.
        var latest = stat()
        try handle.seek(toOffset: 0)
        guard fstatat(directory, ProjectStore.projectFileName, &latest, AT_SYMLINK_NOFOLLOW) == 0,
              latest.st_dev == identity.st_dev, latest.st_ino == identity.st_ino,
              try handle.readToEnd() == original
        else {
            throw ApelinError(.conflict, "The project changed while it was being renamed. Try again.")
        }
        guard renameat(directory, temporary, directory, ProjectStore.projectFileName) == 0 else {
            throw POSIXError(.EIO)
        }
        _ = fsync(directory)
        return ProjectRenameResponse(projectID: projectID, displayName: request.displayName, changed: true)
    }
}
