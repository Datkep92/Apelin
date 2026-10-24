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
        #expect(prompt.contains("call apelin_skill_read"))
        #expect(prompt.hasSuffix("Current date: \(Self.day(1_800_000_000))"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `apelin_skill_read answers a body, lists and reads the skill's files, and stays in its folder`() async throws {
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
            try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
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

    @Test(.timeLimit(.minutes(1)))
    func `an empty file reads a built-in skill's instructions, and its own files are served`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let runner = try runner(home)
        func call(_ arguments: JSONValue) async throws -> String {
            try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
        }
        #expect(try await call(["name": "tweak-development", "file": ""]).contains("# Tweak development"))
        let guide = try await call(["name": "project-description"])
        #expect(guide.contains("Files in this skill's folder (apelin_skill_read with file): apelin-project.schema.json"))
        let schema = try await call(["name": "project-description", "file": "apelin-project.schema.json"])
        #expect(schema.contains(#""title": "Apelin project description, version 1""#))
    }

    @Test
    func `the project-description skill names every member of the schema`() throws {
        let body = BuiltInSkills.projectDescription.body
        let text = try #require(BuiltInSkills.projectDescription.files["apelin-project.schema.json"])
        let schema = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let definitions = schema["$defs"] as? [String: Any] ?? [:]
        func resolved(_ node: Any?) -> [String: Any] {
            guard var node = node as? [String: Any] else { return [:] }
            if let reference = node["$ref"] as? String, let name = reference.split(separator: "/").last {
                node = definitions[String(name)] as? [String: Any] ?? [:]
            }
            return node
        }
        func members(_ node: [String: Any]) -> [String] {
            (node["properties"] as? [String: Any] ?? [:]).keys.sorted()
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let product = resolved(resolved(properties["products"])["items"])
        let package = resolved(properties["package"])
        let configuration = resolved(resolved(properties["configurations"])["properties"].flatMap { ($0 as? [String: Any])?["Debug"] })
        let named = members(schema) + members(product) + members(package) + members(configuration)
        #expect(named.count > 40, "the walk found the schema's members")
        for member in named {
            #expect(body.contains(member), "the guide never names \(member)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `every built-in skill is listed by name and apelin_skill_read serves its body`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skills = BuiltInSkills.all
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .confirm,
                                       skills: skills, mcpServers: [])
        let names = Set(skills.map(\.name))
        // The device's hard-won rules each have a skill.
        for name in ["tweak-development", "bootstrap-paths", "tweak-runtime", "preference-bundle",
                     "project-description", "external-build", "packaging-and-install",
                     "package-dependencies", "crash-triage"]
        {
            #expect(names.contains(name), "no built-in skill \(name)")
            #expect(prompt.contains("<skill name=\"\(name)\">"), "the prompt does not list \(name)")
        }
        let runner = try runner(home)
        for skill in skills {
            let body = try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString,
                                                 arguments: ["name": .string(skill.name)], cancellation: nil, mcp: nil))
            #expect(body.contains(skill.body.prefix(32)), "apelin_skill_read did not serve \(skill.name)")
            #expect(!prompt.contains(skill.body), "the prompt leaked \(skill.name)'s body")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `the bootstrap-paths skill carries its C helper and apelin_skill_read serves it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skill = try #require(BuiltInSkills.all.first { $0.name == "bootstrap-paths" })
        let header = try #require(skill.files["ApelinBootstrap.h"])
        // The helper is the one that builds for both bootstraps: the roothide
        // branch finds the jbroot from its own image, the rootless branch is
        // the fixed prefix.
        #expect(header.contains("ApelinBootstrapPath"))
        #expect(header.contains("APELIN_BOOTSTRAP_ROOTHIDE"))
        #expect(header.contains(".jbroot-"))
        #expect(header.contains("@\"/var/jb\""))
        let runner = try runner(home)
        let served = try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString,
                                               arguments: ["name": "bootstrap-paths", "file": "ApelinBootstrap.h"],
                                               cancellation: nil, mcp: nil))
        #expect(served == header)
    }

    @Test
    func `the responses section forbids pasting tool output and long recaps`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .confirm,
                                       skills: [], mcpServers: [])
        #expect(prompt.contains("# Responses"))
        #expect(prompt.contains("Do not paste tool output"))
        #expect(prompt.contains("never use a tool just to show"))
        #expect(prompt.contains("progress note is one short line"))
    }

    @Test
    func `the prompt keeps apelin_notification_send for what the user would want to know while away`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .relaxed,
                                       skills: [], mcpServers: [])
        let working = try #require(prompt.range(of: "# Working")?.upperBound)
        let device = try #require(prompt.range(of: "# This device")?.lowerBound)
        let section = prompt[working ..< device]
        #expect(section.contains("tell them with apelin_notification_send"))
        #expect(section.contains("never for routine progress, instead of your reply, or to say you are done"))
    }

    @Test
    func `apelin_skill_read needs no approval in Confirm mode`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let verdict = try ApprovalPolicy(mode: .confirm)
            .evaluate(InvocationFacts(tool: .local(.skillRead)), root: ScopedRoot(home.projectURL))
        #expect(verdict == .allow(.preset("apelin_skill_read")))
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
