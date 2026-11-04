@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// file_read on a file larger than one reply shows: the window asked for is
/// read all the same, so a big file is not out of reach.
@Suite("file_read windows a large file")
struct FileReadWindowTests {
    let home: TemporaryHome
    let runner: ToolRunner

    init() throws {
        home = try TemporaryHome()
        runner = try ToolRunner(
            sessionID: UUID().uuidString,
            project: home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
    }

    // MARK: Windows

    @Test
    func `a window deep inside a file larger than one reply is read`() async throws {
        defer { home.remove() }
        try write("big/deep.txt", lines: 8000, width: 200)

        let shown = lines(of: text(try await read(["path": "big/deep.txt", "offset": 6998, "limit": 3])))
        #expect(shown.count == 4)
        #expect(shown[0].hasPrefix("6998\t6998\txxx"))
        #expect(shown[1].hasPrefix("6999\t6999\t"))
        #expect(shown[2].hasPrefix("7000\t7000\t"))
        #expect(shown[3] == "... more lines; continue with offset 7001")
    }

    @Test
    func `the end of a large file is reached, with nothing more to read`() async throws {
        defer { home.remove() }
        try write("big/tail.txt", lines: 8000, width: 200)

        let output = text(try await read(["path": "big/tail.txt", "offset": 7999, "limit": 5]))
        let shown = lines(of: output)
        #expect(shown.count == 4)
        #expect(shown[0].hasPrefix("7999\t7999\t"))
        #expect(shown[1].hasPrefix("8000\t8000\t"))
        #expect(shown[2] == "8001\t", "the newline ending the last line leaves an empty one")
        #expect(shown[3] == "")
        #expect(!output.contains("more lines"))
        #expect(!output.contains("one reply shows"))
    }

    @Test
    func `an offset past the end says how many lines the file has`() async throws {
        defer { home.remove() }
        try write("big/end.txt", lines: 8000, width: 200)

        let output = text(try await read(["path": "big/end.txt", "offset": 90000]))
        #expect(output == "(big/end.txt has 8001 lines)")
    }

    @Test
    func `the byte budget stops the window and says where to go on`() async throws {
        defer { home.remove() }
        try write("big/wide.txt", lines: 8000, width: 200)

        let output = text(try await read(["path": "big/wide.txt", "limit": 3000]))
        let shown = lines(of: output)
        let numbered = shown.filter { $0.first?.isNumber == true }
        #expect(numbered.count > 1000, "the limit of 3000 lines is not reached: the bytes are")
        #expect(numbered.count < 3000)
        let next = numbered.count + 1
        #expect(
            shown.contains(
                "... one reply shows \(ProjectFileTools.maxReadBytes) bytes of it at most; continue with offset \(next)",
            ),
        )
        let resumed = lines(of: text(try await read(["path": "big/wide.txt", "offset": next, "limit": 2])))
        #expect(resumed[0].hasPrefix("\(next)\t"), "the offset the note gives does go on there")
    }

    // MARK: - Helpers

    /// A file of `count` numbered lines of `width` bytes each, so the file is
    /// larger than one reply shows.
    private func write(_ relative: String, lines count: Int, width: Int) throws {
        let filler = String(repeating: "x", count: width - 8)
        var text = ""
        for number in 1 ... count {
            text += "\(number)\t\(filler)\n"
        }
        try home.write(relative, text)
    }

    private func read(_ arguments: JSONValue) async throws -> AgentToolResult {
        try await runner.run(.local(.fileRead), toolCallID: "read", arguments: arguments, cancellation: nil, mcp: nil)
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { block in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined(separator: "\n")
    }

    private func lines(of text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
