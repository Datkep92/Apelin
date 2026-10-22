@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Skills and the system prompt")
struct SkillAndPromptTests {
    private func writeSkill(_ home: TemporaryHome, folder: String, name: String, body: String, files: [String: String] = [:]) throws {
        let directory = home.dataRoot.skills.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skill = "---\nname: \(name)\ndescription: Use for \(name) work.\n---\n\(body)\n"
        try skill.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func runner(_ home: TemporaryHome) throws -> ToolRunner {
        try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                       policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                       gate: ApprovalGate { _ in }, skills: home.dataRoot.skills)
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(content) = $0 {
                content.text
            } else {
                nil
            }
        }
        .joined()
    }

    @Test
    func `the prompt lists skills by name and description, never their bodies`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try writeSkill(home, folder: "theme", name: "theme-colours", body: "skill-body-marker")
        let skills = SkillCatalog.load(userDirectory: home.dataRoot.skills).skills
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .confirm,
                                       skills: skills, mcpServers: [],
                                       date: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(prompt.contains("<skill name=\"theme-colours\" source=\"user\">Use for theme-colours work.</skill>"))
        #expect(prompt.contains("<skill name=\"tweak-development\">"))
        #expect(!prompt.contains("skill-body-marker"))
        #expect(!prompt.contains(BuiltInSkills.all[0].body))
        #expect(prompt.contains("call read_skill"))
        #expect(prompt.hasSuffix("Current date: \(Self.day(1_800_000_000))"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `read_skill answers a body, lists and reads the skill's files, and stays in its folder`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try writeSkill(home, folder: "theme", name: "theme-colours", body: "Use the palette.",
                       files: ["references/palette.md": "palette-marker", ".hidden/secret.md": "hidden"])
        try "outside-marker".write(to: home.dataRoot.skills.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: home.dataRoot.skills.appendingPathComponent("theme/link.md").path,
            withDestinationPath: home.dataRoot.skills.appendingPathComponent("outside.txt").path,
        )
        let runner = try runner(home)
        func call(_ arguments: JSONValue) async throws -> String {
            try await text(runner.run(.local(.readSkill), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
        }

        let body = try await call(["name": "theme-colours"])
        #expect(body.contains("Use the palette."))
        #expect(body.contains("references/palette.md"))
        #expect(!body.contains(".hidden"))
        #expect(!body.contains("link.md"))
        #expect(try await call(["name": "theme-colours", "file": "references/palette.md"]) == "palette-marker")
        #expect(try await call(["name": "tweak-development"]).contains(BuiltInSkills.all[0].body))

        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "../outside.txt"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "link.md"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "tweak-development", "file": "x.md"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await call(["name": "missing"]) }
    }

    @Test
    func `read_skill needs no approval in Confirm mode`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let verdict = try ApprovalPolicy(mode: .confirm)
            .evaluate(InvocationFacts(tool: .local(.readSkill)), root: ScopedRoot(home.projectURL))
        #expect(verdict == .allow(.preset("read_skill")))
    }

    @Test
    func `project instructions come from AGENTS.md, then CLAUDE.md, only inside the project`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        #expect(SystemPrompt.projectInstructions(in: root) == nil)

        try home.write("CLAUDE.md", "claude-marker")
        #expect(SystemPrompt.projectInstructions(in: root) == ProjectInstructions(file: "CLAUDE.md", text: "claude-marker"))
        try home.write("AGENTS.md", "  agents-marker\n")
        let instructions = try #require(SystemPrompt.projectInstructions(in: root))
        #expect(instructions == ProjectInstructions(file: "AGENTS.md", text: "agents-marker"))

        let prompt = SystemPrompt.make(project: home.project, projectRoot: root.path, mode: .relaxed, skills: [],
                                       mcpServers: [], projectInstructions: instructions)
        #expect(prompt.contains("# Project instructions (AGENTS.md)"))
        #expect(prompt.contains("agents-marker"))

        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("AGENTS.md"))
        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("CLAUDE.md"))
        let outside = home.home.appendingPathComponent("outside.md")
        try "outside-marker".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent("AGENTS.md").path,
                                                   withDestinationPath: outside.path)
        #expect(SystemPrompt.projectInstructions(in: root) == nil)

        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("AGENTS.md"))
        try home.write("AGENTS.md", String(repeating: "a", count: SystemPrompt.maxInstructionBytes + 10))
        #expect(SystemPrompt.projectInstructions(in: root)?.text.hasSuffix("… (truncated)") == true)
    }

    private static func day(_ seconds: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
