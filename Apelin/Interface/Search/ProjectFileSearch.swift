import Foundation

/// Finds a project's files by their name and by what is written in them, for
/// the Files screen's search field (`FileExplorerViewController`).
///
/// The project's folder is on this device, so a search is a walk of it and a
/// read of the files whose name does not already answer: it belongs off the
/// main thread, and it stops at `limit` answers rather than building an index
/// nothing would keep up to date.
enum ProjectFileSearch {
    /// A file that answers the words.
    struct Hit: Equatable, Sendable {
        /// The path relative to the project root, e.g.
        /// `Apelin/Interface/Search/TextSearch.swift`.
        var path: String
        /// True when the words were found in the file rather than in its name,
        /// which the row shows with a different symbol.
        var inContent: Bool
        /// The line holding the words, when they were found in the file.
        var line: String?

        /// The file's own name, which the row shows.
        var name: String { (path as NSString).lastPathComponent }
        /// The folder it sits in, which the row shows for a name match.
        var directory: String {
            let folder = (path as NSString).deletingLastPathComponent
            return folder.isEmpty ? "." : folder
        }
    }

    /// As many files as a search answers — files whose path holds the words
    /// and, separately, files whose words do.
    static let limit = 200
    /// A file longer than this is not read for words: a search reads a project,
    /// it does not index it.
    static let sizeLimit = 1 << 20

    /// Folders a search never walks into, hidden ones aside (`.git` among
    /// them, which the walk skips as one): they hold what a build or a
    /// dependency put there, not what the reader wrote.
    private static let skippedFolders: Set<String> = [
        "build", ".build", "DerivedData", "node_modules", "Pods", ".apelinbak",
    ]

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]

    /// The files under `root` answering `query`, the ones named for the words
    /// before the ones holding them, each group by path.
    ///
    /// Blocking: it reads a file per candidate. Call it off the main thread.
    static func search(_ query: String, in root: URL) -> [Hit] {
        guard !query.isEmpty else { return [] }
        var named: [Hit] = []
        var spoken: [Hit] = []
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
        )
        while let url = walker?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) { walker?.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard let path = relativePath(of: url, from: root), !path.isEmpty else { continue }
            if TextSearch.holds(path, query) {
                if named.count < limit { named.append(Hit(path: path, inContent: false, line: nil)) }
            } else if spoken.count < limit,
                      let size = values?.fileSize,
                      size > 0, size <= sizeLimit,
                      let data = try? Data(contentsOf: url),
                      let words = String(data: data, encoding: .utf8),
                      let line = TextSearch.line(of: words, holding: query) {
                spoken.append(Hit(path: path, inContent: true, line: line))
            }
            if named.count >= limit, spoken.count >= limit { break }
        }
        return named.sorted { $0.path < $1.path } + spoken.sorted { $0.path < $1.path }
    }

    /// `url`'s path as the reader says it, relative to the project root; nil
    /// for anything outside it.
    private static func relativePath(of url: URL, from root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
