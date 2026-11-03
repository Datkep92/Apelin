import CryptoKit
import Foundation
import KWWKAI

/// The file tools, implemented here against the project root as mobile.
/// Every path goes through `ScopedRoot`; nothing leaves the project. The
/// reads also run against a read-only root outside it (`ReadOnlyRoots`).
struct ProjectFileTools: Sendable {
    let root: ScopedRoot
    /// For a read-only root outside the project, the folder its paths are
    /// shown under, as the system prompt names it, so a result can be read
    /// again; nil for the project, whose paths are shown relative to it.
    var shownRoot: String?
    /// Where a copy of what a write replaces is kept, for `file_revert`;
    /// nil when this session keeps none, and then a write reports no backup.
    var backups: FileBackups?

    static let maxReadBytes = 512 * 1024
    /// As large as a message's attachment may be, so one sent can be looked
    /// at again.
    static let maxImageFileBytes = AgentSession.maximumAttachmentBytes
    static let maxGrepFileBytes = 2 * 1024 * 1024
    static let maxWalkEntries = 20000

    /// The hash a write reports and `expected_sha256` checks: the whole of a
    /// SHA-256 in hex, so a value copied out of one result is a value the
    /// next call takes.
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Writes

    func writeFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let content = try arguments.requireString("content")
        let target = try root.resolveForWrite(path)
        let relative = root.relative(target.finalPath)
        var before: Data? = Data()
        if target.exists {
            before = try? readData(target.finalPath, limit: FileBackups.maxBytes)
        }
        try requireUnchanged(arguments, path: relative, current: before)
        let backup = target.exists ? keepBackup(before, path: relative) : ""
        try target.commit(Data(content.utf8), exclusive: false)
        let change = LineDiff.counts(old: before.map { String(decoding: $0, as: UTF8.self) } ?? "", new: content)
        let written = Data(content.utf8)
        return "\(target.exists ? "Replaced" : "Created") \(relative) (\(written.count) bytes, \(change))"
            + " sha256 \(Self.digest(written))\(backup)"
    }

    func createFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let content = try arguments.requireString("content")
        let target = try root.resolveForWrite(path)
        if target.exists {
            throw PathPolicyError.alreadyExists(path)
        }
        try target.commit(Data(content.utf8), exclusive: true)
        let written = Data(content.utf8)
        return "Created \(root.relative(target.finalPath)) (\(written.count) bytes, \(LineDiff.counts(old: "", new: content)))"
            + " sha256 \(Self.digest(written))"
    }

    func patchFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let oldText = try arguments.requireString("old_text")
        let newText = try arguments.requireString("new_text")
        let replaceAll = arguments.argBool("replace_all") ?? false
        guard !oldText.isEmpty else { throw ToolArgumentError("old_text is empty") }

        let target = try root.resolveForWrite(path)
        guard target.exists else { throw PathPolicyError.notFound(path) }
        let original = try readText(target.finalPath)
        let occurrences = original.components(separatedBy: oldText).count - 1
        guard occurrences > 0 else { throw ToolArgumentError("old_text does not occur in \(path)") }
        if occurrences > 1, !replaceAll {
            throw ToolArgumentError(
                "old_text occurs \(occurrences) times in \(path); give more context or set replace_all",
            )
        }
        let updated: String
        if replaceAll {
            updated = original.replacingOccurrences(of: oldText, with: newText)
        } else {
            let range = original.range(of: oldText)!
            updated = original.replacingCharacters(in: range, with: newText)
        }
        let relative = root.relative(target.finalPath)
        let originalBytes = try readData(target.finalPath, limit: Self.maxReadBytes)
        try requireUnchanged(arguments, path: relative, current: originalBytes)
        let backup = keepBackup(originalBytes, path: relative)
        try target.commit(Data(updated.utf8), exclusive: false)
        let diff = LineDiff.unified(old: original, new: updated, path: relative)
        let change = LineDiff.counts(old: original, new: updated)
        let written = Data(updated.utf8)
        return "Patched \(relative) (\(replaceAll ? occurrences : 1) replacement\(replaceAll && occurrences > 1 ? "s" : ""), \(change))"
            + " sha256 \(Self.digest(written))\(backup)\n\(diff)"
    }

    /// Restores one of the copies a write kept. Without `backup`, the newest
    /// copy of `path`; the file as it is now is kept first, so a revert is
    /// itself a step back.
    func revertFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        guard let backups else {
            throw ToolArgumentError("this session keeps no copies of project files")
        }
        let target = try root.resolveForWrite(path)
        guard target.exists else { throw PathPolicyError.notFound(path) }
        let relative = root.relative(target.finalPath)
        let found: (copy: FileBackups.Copy, data: Data)?
        if let name = arguments.argNonEmptyString("backup") {
            found = try backups.find(named: name)
            guard found != nil else { throw ToolArgumentError("\(relative) has no copy named \(name)") }
        } else {
            found = try backups.newest(of: relative)
            guard found != nil else { throw ToolArgumentError("\(relative) has no saved copy; only a write or an edit keeps one") }
        }
        guard let (copy, data) = found else { throw ToolArgumentError("\(relative) has no saved copy") }
        let current = try? readData(target.finalPath, limit: FileBackups.maxBytes)
        let kept = keepBackup(current, path: relative)
        try target.commit(data, exclusive: false)
        let when = ISO8601DateFormatter().string(from: copy.savedAt)
        return "Restored \(relative) from \(copy.name) (saved \(when), \(data.count) bytes)"
            + " sha256 \(Self.digest(data))\(kept)"
    }

    /// The copies a path has, newest first: what `file_revert` would reach.
    func listBackups(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        guard let backups else {
            throw ToolArgumentError("this session keeps no copies of project files")
        }
        let relative = root.relative(try root.resolveForWrite(path).finalPath)
        let copies = try backups.copies(of: relative)
        guard !copies.isEmpty else {
            return "No saved copy of \(relative). A copy is kept each time file_write or file_edit replaces it, the newest \(FileBackups.limit) across the project."
        }
        let formatter = ISO8601DateFormatter()
        let lines = copies.prefix(20).map { copy in
            "\(copy.name)  \(copy.bytes) bytes  saved \(formatter.string(from: copy.savedAt))"
        }
        let more = copies.count > 20 ? "\n\(copies.count - 20) older copies not listed" : ""
        return "\(copies.count) saved copy\(copies.count == 1 ? "" : "ies") of \(relative), newest first:\n"
            + lines.joined(separator: "\n") + more
            + "\nfile_revert restores one, by name or the newest."
    }

    // MARK: - Writes: checks

    /// Refuses a write whose `expected_sha256` is not the file's content: the
    /// model read a revision that has changed since, and writing over it
    /// would lose what someone else wrote.
    private func requireUnchanged(_ arguments: JSONValue, path: String, current: Data?) throws {
        guard let expected = arguments.argNonEmptyString("expected_sha256") else { return }
        guard let current else {
            throw ToolArgumentError("\(path) is over \(FileBackups.maxBytes) bytes, so its sha256 is not checked; omit expected_sha256")
        }
        let actual = Self.digest(current)
        let wanted = expected.lowercased().trimmingCharacters(in: .whitespaces)
        guard actual == wanted else {
            throw ToolArgumentError("\(path) is not the file that hash describes (it is sha256 \(actual) now); read it again and retry")
        }
    }

    /// Keeps a copy of what a write is about to replace, and answers the
    /// words the result adds: nothing when this session keeps none, the
    /// copy's name when one was saved, and why when none could be.
    private func keepBackup(_ data: Data?, path: String) -> String {
        guard let backups else { return "" }
        guard let data else { return " no backup (over \(FileBackups.maxBytes) bytes)" }
        do {
            guard let name = try backups.save(data, path: path) else { return " backup already current" }
            return " backup \(name)"
        } catch {
            return " no backup (\(error.localizedDescription))"
        }
    }

    // MARK: - Reads

    /// What file_read says of a file it cannot show, too large or not text.
    static let unreadableHint = "file_read shows a PNG, JPEG, GIF, HEIC, WebP, TIFF or BMP image as a picture; "
        + "for a video, extract frames as image files first (ffmpeg through shell_run, where it is installed) and read those"

    func readFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let real = try root.resolveExisting(path)
        let text: String
        do {
            text = try readText(real)
        } catch let refusal as ToolArgumentError {
            throw ToolArgumentError("\(refusal.message); \(Self.unreadableHint)")
        }
        let lines = text.components(separatedBy: "\n")
        let offset = max(1, arguments.argInt("offset") ?? 1)
        let limit = max(1, arguments.argInt("limit") ?? 2000)
        guard offset <= max(lines.count, 1) else { return "(\(path) has \(lines.count) lines)" }
        let slice = lines[(offset - 1) ..< min(lines.count, offset - 1 + limit)]
        var output = ""
        for (index, line) in slice.enumerated() {
            output += "\(offset + index)\t\(line)\n"
        }
        if offset - 1 + limit < lines.count {
            output += "… \(lines.count - (offset - 1 + limit)) more lines; continue with offset \(offset + limit)\n"
        }
        return output
    }

    /// An image file as file_read shows it, a picture; nil when the file is
    /// not one, and file_read reads it as text.
    func readImage(_ arguments: JSONValue) throws -> FileImage? {
        let path = try arguments.requireString("path")
        let real = try root.resolveExisting(path)
        let file = try openRegularFile(real)
        defer { close(file.descriptor) }
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false)
        let head = try handle.read(upToCount: FileImage.sniffedBytes) ?? Data()
        guard let format = FileImage.format(of: head) else { return nil }
        let name = shown(real)
        guard file.size <= Self.maxImageFileBytes else {
            throw ToolArgumentError(
                "\(name) is a \(format) image of \(file.size) bytes, over the \(Self.maxImageFileBytes)-byte limit",
            )
        }
        let data = head + handle.readDataToEndOfFile()
        if let image = try FileImage.read(data, frame: arguments.argInt("frame"), name: name) {
            return image
        }
        // Text that begins as an image does is read as text.
        guard !data.prefix(8192).contains(0) else {
            throw ToolArgumentError("\(name) begins as a \(format) image does, but it could not be decoded")
        }
        return nil
    }

    func list(_ arguments: JSONValue) throws -> String {
        let path = arguments.argString("path") ?? "."
        let depth = min(4, max(1, arguments.argInt("depth") ?? 1))
        let real = try root.resolveExisting(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PathPolicyError.notADirectory(path)
        }
        var lines: [String] = []
        walk(real, depth: depth, prefix: "") { entry, isDirectory, indent in
            lines.append("\(indent)\(entry)\(isDirectory ? "/" : "")")
            return lines.count < 2000
        }
        return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
    }

    func find(_ arguments: JSONValue) throws -> String {
        let pattern = try arguments.requireString("pattern")
        let path = arguments.argString("path") ?? "."
        let maxResults = min(2000, max(1, arguments.argInt("max_results") ?? 200))
        let real = try root.resolveExisting(path)
        var results: [String] = []
        enumerateFiles(under: real) { file in
            if fnmatch(pattern, (file as NSString).lastPathComponent, 0) == 0 {
                results.append(shown(file))
            }
            return results.count < maxResults
        }
        return results.isEmpty ? "(no matches)" : results.joined(separator: "\n")
    }

    func grep(_ arguments: JSONValue) throws -> String {
        let pattern = try arguments.requireString("pattern")
        let path = arguments.argString("path") ?? "."
        let glob = arguments.argString("glob")
        let maxResults = min(1000, max(1, arguments.argInt("max_results") ?? 100))
        let options: NSRegularExpression.Options = (arguments.argBool("ignore_case") ?? false) ? [.caseInsensitive] : []
        let expression: NSRegularExpression
        do { expression = try NSRegularExpression(pattern: pattern, options: options) } catch {
            throw ToolArgumentError("invalid regular expression: \(pattern)")
        }
        let real = try root.resolveExisting(path)
        var results: [String] = []

        func search(_ file: String) {
            if let glob, fnmatch(glob, (file as NSString).lastPathComponent, 0) != 0 {
                return
            }
            guard let text = try? readText(file, limit: Self.maxGrepFileBytes) else { return }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if expression.firstMatch(in: line, range: range) != nil {
                    let excerpt = line.count > 300 ? String(line.prefix(300)) + "…" : line
                    results.append("\(shown(file)):\(index + 1): \(excerpt)")
                    if results.count >= maxResults {
                        return
                    }
                }
            }
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            enumerateFiles(under: real) { file in
                search(file)
                return results.count < maxResults
            }
        } else {
            search(real)
        }
        return results.isEmpty ? "(no matches)" : results.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Reads UTF-8 text from a canonical path inside the root. Refuses
    /// binary files and files over the limit.
    func readText(_ canonical: String, limit: Int = maxReadBytes) throws -> String {
        let data = try readData(canonical, limit: limit)
        if data.prefix(8192).contains(0) {
            throw ToolArgumentError("\(shown(canonical)) is a binary file")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The bytes of a regular file at a canonical path inside the root,
    /// opened without following a link. Refuses files over the limit.
    func readData(_ canonical: String, limit: Int) throws -> Data {
        let file = try openRegularFile(canonical)
        defer { close(file.descriptor) }
        guard file.size <= limit else {
            throw ToolArgumentError(
                "\(shown(canonical)) is \(file.size) bytes, over the \(limit)-byte limit",
            )
        }
        // One byte past the limit, for a file that grew since fstat.
        let data = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false).readData(ofLength: limit + 1)
        guard data.count <= limit else {
            throw ToolArgumentError("\(shown(canonical)) grew past the \(limit)-byte limit while it was read")
        }
        return data
    }

    /// Opens a canonical path inside the root, without following a link,
    /// when it is a regular file. The caller closes the descriptor.
    private func openRegularFile(_ canonical: String) throws -> (descriptor: Int32, size: Int) {
        guard root.contains(canonical) else { throw PathPolicyError.outsideRoot(canonical) }
        let fd = open(canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw PathPolicyError.io("could not open \(shown(canonical)): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw PathPolicyError.notAFile(shown(canonical))
        }
        return (fd, Int(info.st_size))
    }

    /// `canonical` as results name it: relative to the project, or under
    /// `shownRoot`.
    private func shown(_ canonical: String) -> String {
        let relative = root.relative(canonical)
        guard let shownRoot else { return relative }
        return relative == "." ? shownRoot : (shownRoot as NSString).appendingPathComponent(relative)
    }

    /// Regular files below `directory`, without following links out of the
    /// root and skipping `.git` and build output.
    private func enumerateFiles(under directory: String, _ body: (String) -> Bool) {
        var visited = 0
        var stack = [directory]
        while let current = stack.popLast() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: current) else { continue }
            for entry in entries.sorted() {
                visited += 1
                if visited > Self.maxWalkEntries {
                    return
                }
                if entry == ".git" || entry == ".build" || entry == ".apelin" {
                    continue
                }
                let full = (current as NSString).appendingPathComponent(entry)
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: stack.append(full)
                case S_IFREG: if !body(full) {
                        return
                    }
                default: continue // links are not followed
                }
            }
        }
    }

    private func walk(_ directory: String, depth: Int, prefix: String, _ body: (String, Bool, String) -> Bool) {
        guard depth > 0, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries.sorted() {
            let full = (directory as NSString).appendingPathComponent(entry)
            var info = stat()
            guard lstat(full, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let isDirectory = kind == S_IFDIR
            let label = kind == S_IFLNK ? "\(entry) -> (link)" : entry
            if !body(label, isDirectory, prefix) {
                return
            }
            if isDirectory {
                walk(full, depth: depth - 1, prefix: prefix + "  ", body)
            }
        }
    }
}

/// A small line diff for `file_edit` results: the changed hunk with three
/// lines of context, in unified form.
enum LineDiff {
    /// Lines added and removed, as `+a -b`: the first line of every file
    /// tool's result ends with it, and the app reads it from there. Like
    /// `unified`, it counts the one span between the unchanged ends.
    static func counts(old: String, new: String) -> String {
        let a = lines(old)
        let b = lines(new)
        let (prefix, suffix) = span(a, b)
        return "+\(b.count - prefix - suffix) -\(a.count - prefix - suffix)"
    }

    /// How many lines the two versions share at the start, then at the end
    /// of what is left: the changed span lies between them.
    private static func span<T: Equatable>(_ a: [T], _ b: [T]) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return (prefix, suffix)
    }

    /// Lines of a file, without the empty one after a final newline.
    private static func lines(_ text: String) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    static func unified(old: String, new: String, path: String) -> String {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let (prefix, suffix) = span(a, b)
        let context = 3
        let start = max(0, prefix - context)
        let aEnd = a.count - suffix
        let bEnd = b.count - suffix
        let aContextEnd = min(a.count, aEnd + context)
        var lines = [
            "--- a/\(path)",
            "+++ b/\(path)",
            "@@ -\(start + 1),\(aContextEnd - start) +\(start + 1),\(min(b.count, bEnd + context) - start) @@",
        ]
        for line in a[start ..< prefix] {
            lines.append(" \(line)")
        }
        for line in a[prefix ..< aEnd] {
            lines.append("-\(line)")
        }
        for line in b[prefix ..< bEnd] {
            lines.append("+\(line)")
        }
        for line in a[aEnd ..< aContextEnd] {
            lines.append(" \(line)")
        }
        if lines.count > 400 {
            return lines.prefix(400).joined(separator: "\n") + "\n… diff truncated"
        }
        return lines.joined(separator: "\n")
    }
}
