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
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: skills, mcpServers: [])
        #expect(prompt.contains("<skill name=\"theme-colours\" source=\"user\">Use for theme-colours work.</skill>"))
        #expect(prompt.contains("<skill name=\"apelin-tweak-development\">"))
        #expect(!prompt.contains("skill-body-marker"))
        #expect(!prompt.contains(BuiltInSkills.all[0].body))
        #expect(prompt.contains("call apelin_skill_read"))
        // The date and the mode on are each message's (`SystemState`).
        #expect(!prompt.contains("Current date"))
        #expect(prompt.hasSuffix("</available_skills>"))
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
        #expect(try await call(["name": "apelin-tweak-development"]).contains(BuiltInSkills.all[0].body))

        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "../outside.txt"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "link.md"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "apelin-tweak-development", "file": "x.md"]) }
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
        #expect(try await call(["name": "apelin-tweak-development", "file": ""]).contains("# Tweak development"))
        let guide = try await call(["name": "apelin-project-description"])
        #expect(guide.contains("Files in this skill's folder (apelin_skill_read with file): apelin-project.schema.json"))
        let schema = try await call(["name": "apelin-project-description", "file": "apelin-project.schema.json"])
        #expect(schema.contains(#""title": "Apelin project description, version 1""#))
    }

    @Test
    func `the apelin-project-description skill names every member of the schema`() throws {
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
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: skills, mcpServers: [])
        let names = Set(skills.map(\.name))
        // The device's hard-won rules each have a skill.
        for name in ["apelin-tweak-development", "apelin-bootstrap-paths", "apelin-tweak-runtime", "apelin-preference-bundle",
                     "apelin-project-description", "apelin-external-build", "apelin-packaging-and-install",
                     "apelin-package-dependencies", "apelin-crash-triage", "apelin-icli"]
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
    func `the apelin-bootstrap-paths skill carries its C helper and apelin_skill_read serves it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-bootstrap-paths" })
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
                                               arguments: ["name": "apelin-bootstrap-paths", "file": "ApelinBootstrap.h"],
                                               cancellation: nil, mcp: nil))
        #expect(served == header)
    }

    @Test
    func `the responses section forbids pasting tool output and long recaps`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        #expect(prompt.contains("# Responses"))
        #expect(prompt.contains("- Reply in the language the user writes in. When that is unclear (code, a log, a single word, a pasted file), reply in the system language that <system-state> names."))
        #expect(prompt.contains("Code, identifiers, paths and commit messages stay as the repository has them"))
        #expect(prompt.contains("Do not paste tool output"))
        #expect(prompt.contains("never use a tool just to show"))
        #expect(prompt.contains("progress note is one short line"))
    }

    /// On a device, General Chat asked how to make a tweak with Apelin was
    /// answered from what the model knew of Theos: a Logos `Tweak.x` with
    /// `%hook`, and no skill read.
    @Test
    func `every chat is told an Apelin tweak is plain Objective-C and to read the skill before explaining`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: BuiltInSkills.all, mcpServers: [])
            let working = try #require(prompt.range(of: "# Working")?.upperBound)
            let device = try #require(prompt.range(of: "# This device")?.lowerBound)
            let section = prompt[working ..< device]
            #expect(section.contains("An Apelin tweak is plain Objective-C: hooks installed with MSHookMessageEx"))
            #expect(section.contains("There is no Logos (%hook, .x files) and no Theos here."))
            #expect(section.contains("a question included, read the matching skill with apelin_skill_read"))
        }
        // The file the prompt names is the tweak template's.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let template = repository.appendingPathComponent(
            "Extensions/Development/wiki.qaq.apelin.dev.tweak/templates/objc-hook/Sources/Tweak.m",
        )
        let source = try String(contentsOf: template, encoding: .utf8)
        #expect(source.contains("MSHookMessageEx"))
    }

    /// On a device, a pane's chat looked for PSListController.h in the
    /// extension's support folder with the file tools, was told it was
    /// outside the project, and read it through the shell instead.
    @Test
    func `the apelin-preference-bundle skill names the Preferences header where the read tools reach it`() throws {
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-preference-bundle" })
        let installed = "wiki.qaq.apelin.dev.preferences/support/include/Preferences/PSListController.h"
        #expect(skill.body.contains("`<install root>/usr/share/apelin/development/\(installed)`"))
        let words = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(words.contains("Read it with file_read"))
        #expect(ReadOnlyRoots(installRoot: "/var/jb", dataRoot: ApelinDataRoot(home: URL(fileURLWithPath: "/var/mobile")))
            .developmentExtensions == "/var/jb/usr/share/apelin/development")
        // The extension's packager installs the repository's header there.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let header = try String(contentsOf: repository.appendingPathComponent("Extensions/Development/" + installed), encoding: .utf8)
        #expect(header.contains("@interface PSSpecifier"))
    }

    @Test
    func `the prompt keeps apelin_notification_send for what the user would want to know while away`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
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

        let prompt = SystemPrompt.make(project: home.project, projectRoot: root.path, skills: [],
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
}
