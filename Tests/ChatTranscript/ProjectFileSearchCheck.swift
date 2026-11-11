import ApelinCore
import ApelinProtocol
import Foundation

/// Searching a project's files, over a folder made for the test: by name, by
/// what a file holds, over the whole project, and never through what a build or
/// a repository put there.
func checkProjectFileSearch() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("apelin-file-search-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    func write(_ path: String, _ words: String) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try words.write(to: url, atomically: true, encoding: .utf8)
    }

    try write("README.md", "The sidebar search finds what was said\n")
    try write("Apelin/Interface/Root/SidebarController.swift", "let needle = 1\n")
    try write("Apelin/Notes.md", String(repeating: "x", count: 200) + " needle " + String(repeating: "y", count: 200))
    try write("build/generated.swift", "let needle = 2\n")
    try write(".git/config", "needle\n")
    try write("big.txt", String(repeating: "x", count: ProjectFileSearch.sizeLimit + 1) + "needle")

    // a name answers from anywhere in the project, whatever its case, with the
    // folder it sits in
    let named = ProjectFileSearch.search("sidebarcontroller", in: root)
    precondition(named.count == 1, "one file is named for the words: \(named.map(\.path))")
    precondition(named[0].path == "Apelin/Interface/Root/SidebarController.swift")
    precondition(named[0].name == "SidebarController.swift" && named[0].directory == "Apelin/Interface/Root")
    precondition(!named[0].inContent && named[0].line == nil, "a name match is not a content match")

    // files named for the words come before files that hold them
    let both = ProjectFileSearch.search("sidebar", in: root)
    precondition(both.map(\.path) == [
        "Apelin/Interface/Root/SidebarController.swift", "README.md",
    ], "named first, then the words: \(both.map(\.path))")
    precondition(both[1].inContent && both[1].line == "The sidebar search finds what was said")

    // and a match inside a file answers with the line it is in, whatever its
    // case, cut around the words when the line runs on
    let said = ProjectFileSearch.search("SIDEBAR SEARCH", in: root)
    precondition(said.count == 1 && said[0].path == "README.md" && said[0].line == "The sidebar search finds what was said")
    precondition(said[0].inContent)
    let cut = ProjectFileSearch.search("needle", in: root)
    precondition(cut.map(\.path) == ["Apelin/Interface/Root/SidebarController.swift", "Apelin/Notes.md"], "cut around the words: \(cut.map(\.path))")
    precondition(cut[1].line?.contains("needle") == true && cut[1].line?.hasPrefix("...") == true)

    // a build's folder, a repository's, and a file too long to read are left
    // alone; `build/generated.swift` would otherwise be the second hit
    precondition(!cut.contains { $0.path.hasPrefix("build/") || $0.path.hasPrefix(".git/") })
    precondition(!cut.contains { $0.path == "big.txt" }, "a file longer than the read is not read")

    // nothing searched for, and a folder that holds nothing
    precondition(ProjectFileSearch.search("", in: root).isEmpty)
    let empty = root.appendingPathComponent("nothing-\(UUID().uuidString)")
    precondition(ProjectFileSearch.search("needle", in: empty).isEmpty)
    print("ok: a project is searched for a file by its name and by what it holds")
}
