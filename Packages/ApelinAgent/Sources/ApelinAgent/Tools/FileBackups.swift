import CryptoKit
import Foundation

/// Copies of what a write replaces, kept outside the project so a rollback
/// never lands in the user's repository: `~/Documents/wiki.qaq.apelin/
/// backups/<project>/`, beside `Projects/`.
///
/// A copy's name carries what finds it again — `<epoch-ms>-<path hash>-
/// <content hash>-<name>` — so listing a file's copies is one folder read,
/// and a save of bytes already the newest copy is no save at all. The folder
/// keeps `limit` copies across every file of the project: a rollback reaches
/// the last few changes, not every change ever made, and a project with a
/// long session does not fill the device.
struct FileBackups: Sendable {
    /// Copies kept, newest first, across the project's files.
    static let limit = 60
    /// The largest file copied. A rollback of a bigger one is the user's,
    /// and copies of that size would fill the folder in a few writes.
    static let maxBytes = 8 * 1024 * 1024

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The folder a project's copies go in.
    static func directory(for name: ProjectName, dataRoot: ApelinDataRoot = .current) -> URL {
        dataRoot.url
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(name.rawValue, isDirectory: true)
    }

    /// One saved copy, as the folder keeps it.
    struct Copy: Sendable, Hashable {
        var name: String
        /// When it was saved, read from its name rather than the file: the
        /// folder is copied around and a copy's own timestamps mean nothing.
        var savedAt: Date
        var bytes: Int
    }

    /// Saves `data` as the newest copy of `path`, a path shown relative to
    /// the project root. Answers the copy's name, or nil when the same bytes
    /// are already the newest copy of that path, or the file is over
    /// `maxBytes`.
    @discardableResult
    func save(_ data: Data, path: String, at date: Date = Date()) throws -> String? {
        guard data.count <= Self.maxBytes else { return nil }
        let digest = Self.hash(data)
        if let newest = try copies(of: path).first, newest.name.contains("-\(digest)-") {
            return nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(Self.milliseconds(date))-\(Self.hash(Data(path.utf8)))-\(digest)-\(Self.label(path))"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        try prune()
        return name
    }

    /// Every copy of `path`, newest first.
    func copies(of path: String) throws -> [Copy] {
        let hash = Self.hash(Data(path.utf8))
        return try all().filter { Self.parts($0.name)?.pathHash == hash }
    }

    /// Every copy in the folder, newest first.
    func all() throws -> [Copy] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
        )) ?? []
        return entries.compactMap { url in
            guard Self.parts(url.lastPathComponent) != nil else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { return nil }
            return Copy(
                name: url.lastPathComponent,
                savedAt: Self.date(url.lastPathComponent),
                bytes: values?.fileSize ?? 0,
            )
        }
        .sorted { $0.name > $1.name }
    }

    /// The newest copy of `path` with its bytes.
    func newest(of path: String) throws -> (copy: Copy, data: Data)? {
        guard let copy = try copies(of: path).first else { return nil }
        return (copy, try load(copy))
    }

    /// One copy by its name, with its bytes; nil when the folder has none.
    func find(named name: String) throws -> (copy: Copy, data: Data)? {
        // The name comes from a tool argument: a copy is only ever a file of
        // this folder, named as the folder names one.
        guard Self.parts(name) != nil else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let copy = try all().first(where: { $0.name == name }) else { return nil }
        return (copy, try Data(contentsOf: url, options: .mappedIfSafe))
    }

    func load(_ copy: Copy) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(copy.name), options: .mappedIfSafe)
    }

    /// Removes the copies past `limit`, oldest first.
    func prune() throws {
        let kept = try all()
        guard kept.count > Self.limit else { return }
        for copy in kept[Self.limit...] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(copy.name))
        }
    }

    // MARK: - Names

    /// A copy's name, read from the left: the epoch, the path's hash, the
    /// content's hash, then the file's own name, which may hold hyphens too.
    static func parts(_ name: String) -> (epoch: Int, pathHash: String, contentHash: String, label: String)? {
        let fields = name.split(separator: "-", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4, let epoch = Int(fields[0]),
              fields[1].count == hashLength, fields[2].count == hashLength,
              // The label is the rest of the name and is the one field a
              // caller can fill: a slash in it would name a file outside the
              // folder, so a name carrying one is no copy of ours.
              !fields[3].contains("/")
        else { return nil }
        return (epoch, String(fields[1]), String(fields[2]), String(fields[3]))
    }

    static func date(_ name: String) -> Date {
        guard let parts = parts(name) else { return .distantPast }
        return Date(timeIntervalSince1970: Double(parts.epoch) / 1000)
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }

    /// The file's own name, made safe for a file name: everything outside
    /// letters, digits, `.`, `_` and `-` becomes `_`.
    private static func label(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? "file"
        let safe = last.unicodeScalars.map { scalar -> Character in
            let ok = CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar)
            return ok ? Character(scalar) : "_"
        }
        return String(String(safe).prefix(60))
    }

    /// Half of a SHA-256, in hex: two revisions of one file do not collide,
    /// and a name stays short enough to read in a tool's result.
    static let hashLength = 16

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(hashLength / 2).map { String(format: "%02x", $0) }.joined()
    }
}