import Foundation
import KWWKAI

/// The file tools, implemented here against the project root as mobile.
/// Every path goes through `ScopedRoot`; nothing leaves the project.
struct ProjectFileTools: Sendable {
    let root: ScopedRoot

    static let maxReadBytes = 512 * 1024
    static let maxGrepFileBytes = 2 * 1024 * 1024
    static let maxWalkEntries = 20000

    // MARK: - Writes

    func writeFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let content = try arguments.requireString("content")
        let target = try root.resolveForWrite(path)
        let original = target.exists ? (try? readText(target.finalPath)) ?? "" : ""
        try target.commit(Data(content.utf8), exclusive: false)
        let change = LineDiff.counts(old: original, new: content)
        return "\(target.exists ? "Replaced" : "Created") \(root.relative(target.finalPath)) (\(content.utf8.count) bytes, \(change))"
    }

    func createFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let content = try arguments.requireString("content")
        let target = try root.resolveForWrite(path)
        if target.exists {
            throw PathPolicyError.alreadyExists(path)
        }
        try target.commit(Data(content.utf8), exclusive: true)
        return "Created \(root.relative(target.finalPath)) (\(content.utf8.count) bytes, \(LineDiff.counts(old: "", new: content)))"
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
        try target.commit(Data(updated.utf8), exclusive: false)
        let diff = LineDiff.unified(old: original, new: updated, path: root.relative(target.finalPath))
        let change = LineDiff.counts(old: original, new: updated)
        return "Patched \(root.relative(target.finalPath)) (\(replaceAll ? occurrences : 1) replacement\(replaceAll && occurrences > 1 ? "s" : ""), \(change))\n\(diff)"
    }

    // MARK: - Reads

    func readFile(_ arguments: JSONValue) throws -> String {
        let path = try arguments.requireString("path")
        let real = try root.resolveExisting(path)
        let text = try readText(real)
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
                results.append(root.relative(file))
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
                    let shown = line.count > 300 ? String(line.prefix(300)) + "…" : line
                    results.append("\(root.relative(file)):\(index + 1): \(shown)")
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
        guard root.contains(canonical) else { throw PathPolicyError.outsideRoot(canonical) }
        let fd = open(canonical, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw PathPolicyError.io("could not open \(root.relative(canonical)): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PathPolicyError.notAFile(root.relative(canonical))
        }
        guard Int(info.st_size) <= limit else {
            throw ToolArgumentError(
                "\(root.relative(canonical)) is \(info.st_size) bytes, over the \(limit)-byte limit",
            )
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        if data.prefix(8192).contains(0) {
            throw ToolArgumentError("\(root.relative(canonical)) is a binary file")
        }
        return String(decoding: data, as: UTF8.self)
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

/// A small line diff for `patch_file` results: the changed hunk with three
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
