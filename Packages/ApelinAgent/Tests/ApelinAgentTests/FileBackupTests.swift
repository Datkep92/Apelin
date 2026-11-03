@testable import ApelinAgent
import Foundation
import Testing

/// The copies a write keeps of what it replaces, and `file_revert` putting
/// one back: kept beside the project, never inside it, so a rollback never
/// lands in the user's repository.
@Suite("Copies of project files, and reverting one")
struct FileBackupTests {
    let home: TemporaryHome
    let backups: FileBackups
    let tools: ProjectFileTools

    init() throws {
        home = try TemporaryHome()
        backups = FileBackups(directory: FileBackups.directory(for: home.project.name, dataRoot: home.dataRoot))
        tools = try ProjectFileTools(root: ScopedRoot(home.projectURL), backups: backups)
    }

    @Test
    func `a copy carries its path, its bytes and when it was saved`() throws {
        defer { home.remove() }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let name = try #require(try backups.save(Data("one\n".utf8), path: "src/a.txt", at: when))
        let parts = try #require(FileBackups.parts(name))
        #expect(parts.label == "a.txt")
        #expect(FileBackups.date(name) == when)
        #expect(try backups.copies(of: "src/a.txt").map(\.name) == [name])
        #expect(try backups.copies(of: "src/b.txt").isEmpty)
        // The same bytes again are the copy already newest: no second one.
        #expect(try backups.save(Data("one\n".utf8), path: "src/a.txt") == nil)
        let second = try #require(try backups.save(
            Data("two\n".utf8),
            path: "src/a.txt",
            at: when.addingTimeInterval(1),
        ))
        #expect(try backups.copies(of: "src/a.txt").map(\.name) == [second, name])
        #expect(try backups.newest(of: "src/a.txt")?.data == Data("two\n".utf8))
        #expect(try backups.find(named: name)?.data == Data("one\n".utf8))
    }

    @Test
    func `a name from a tool argument never reaches a file outside the folder`() throws {
        defer { home.remove() }
        #expect(FileBackups.parts("../../etc/passwd") == nil)
        #expect(FileBackups.parts("1800000000000-0123456789abcdef-0123456789abcdef-a/b") == nil)
        #expect(FileBackups.parts("1800000000000-0123456789abcdef-0123456789abcdef") == nil)
        let name = try #require(try backups.save(Data("one\n".utf8), path: "a.txt"))
        #expect(try backups.find(named: "../../etc/passwd") == nil)
        #expect(FileBackups.parts(name) != nil)
        #expect(FileBackups.parts(name)?.pathHash == FileBackups.hash(Data("a.txt".utf8)))
    }

    @Test
    func `the folder keeps the newest limit copies across every file`() throws {
        defer { home.remove() }
        var saved: [String] = []
        for index in 0 ... FileBackups.limit + 4 {
            let name = try backups.save(
                Data("\(index)\n".utf8),
                path: "n\(index % 3).txt",
                at: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(Double(index)),
            )
            if let name { saved.append(name) }
        }
        #expect(saved.count == FileBackups.limit + 5)
        let kept = try backups.all().map(\.name)
        #expect(kept.count == FileBackups.limit)
        #expect(kept.sorted() == saved.suffix(FileBackups.limit).sorted(), "the oldest are the ones gone")
    }

    @Test
    func `a write keeps what it replaced, and a revert puts it back`() throws {
        defer { home.remove() }
        try home.write("notes.txt", "first\n")
        let written = try tools.writeFile(["path": "notes.txt", "content": "second\n"])
        #expect(written.hasPrefix("Replaced notes.txt (7 bytes"))
        let copies = try backups.copies(of: "notes.txt")
        #expect(copies.count == 1, "the bytes the write replaced")
        let restored = try tools.revertFile(["path": "notes.txt"])
        #expect(try home.read("notes.txt") == "first\n")
        #expect(restored.hasPrefix("Restored notes.txt from \(copies[0].name)"))
        #expect(restored.contains("sha256 \(ProjectFileTools.digest(Data("first\n".utf8)))"))
        // A revert is itself a step back: what it replaced is a copy too.
        let after = try backups.copies(of: "notes.txt").map { try backups.load($0) }
        #expect(after.contains(Data("second\n".utf8)))
    }

    @Test
    func `a revert names one copy, and a file with no copy is refused`() throws {
        defer { home.remove() }
        try home.write("a.txt", "one\n")
        _ = try tools.writeFile(["path": "a.txt", "content": "two\n"])
        _ = try tools.writeFile(["path": "a.txt", "content": "three\n"])
        let copies = try backups.copies(of: "a.txt")
        #expect(copies.count == 2)
        let one = try #require(try copies.first { try backups.load($0) == Data("one\n".utf8) })
        _ = try tools.revertFile(["path": "a.txt", "backup": one.name])
        #expect(try home.read("a.txt") == "one\n")

        let listed = try tools.listBackups(["path": "a.txt"])
        let count = try backups.copies(of: "a.txt").count
        #expect(listed.hasPrefix("\(count) saved copies of a.txt"))

        try home.write("b.txt", "untouched\n")
        #expect(throws: (any Error).self) { _ = try tools.revertFile(["path": "b.txt"]) }
        #expect(throws: (any Error).self) { _ = try tools.revertFile(["path": "missing.txt"]) }
        #expect(throws: (any Error).self) { _ = try tools.revertFile(["path": "a.txt", "backup": "nope"]) }
        #expect(try home.read("b.txt") == "untouched\n")
    }
}