@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("General Chat creates projects")
struct ProjectCreationTests {
    private func runner(_ home: TemporaryHome, project: ProjectIdentity, backend: MockBackend) throws -> ToolRunner {
        try ToolRunner(sessionID: UUID().uuidString, project: project, root: ScopedRoot(home.projectURL),
                       policy: ApprovalPolicy(mode: .confirm), backend: backend, digests: MockDigestLedger(),
                       gate: ApprovalGate { _ in })
    }

    private func generalChat() throws -> ProjectIdentity {
        let id = UUID().uuidString
        return try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
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
    func `only General Chat is offered the project tools`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let names = { (runner: ToolRunner) in Set(runner.agentTools(mcp: []).map(\.name)) }
        let project = try names(runner(home, project: home.project, backend: MockBackend()))
        #expect(!project.contains("project_template_list"))
        #expect(!project.contains("project_create"))
        let general = try names(runner(home, project: generalChat(), backend: MockBackend()))
        #expect(general.contains("project_template_list"))
        #expect(general.contains("project_create"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `project_create takes a template and runs under Confirm without asking`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let runner = try runner(home, project: generalChat(), backend: backend)
        let list = try await runner.run(.local(.projectTemplateList), toolCallID: "call-1", arguments: .object([:]), cancellation: nil, mcp: nil)
        #expect(text(list).contains("wiki.qaq.apelin.dev.tweak/tweak"))
        let arguments: JSONValue = .object([
            "template": "wiki.qaq.apelin.dev.tweak/tweak",
            "name": "Lock Screen Clock",
            "values": .object(["filter": "com.apple.springboard", "verbose": .bool(true), "count": .int(3)]),
        ])
        let created = try await runner.run(.local(.projectCreate), toolCallID: "call-2", arguments: arguments, cancellation: nil, mcp: nil)
        #expect(text(created).contains("project-1"))
        #expect(await backend.calls == [.createProject(
            template: "wiki.qaq.apelin.dev.tweak/tweak",
            name: "Lock Screen Clock",
            values: ["filter": .string("com.apple.springboard"), "verbose": .boolean(true), "count": .integer(3)],
        )])
    }

    @Test(.timeLimit(.minutes(1)))
    func `project_create needs a template and refuses a project's own chat`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backend = MockBackend()
        let general = try runner(home, project: generalChat(), backend: backend)
        await #expect(throws: ToolArgumentError.self) {
            try await general.run(.local(.projectCreate), toolCallID: "call-1", arguments: .object(["name": "Clock"]), cancellation: nil, mcp: nil)
        }
        let project = try runner(home, project: home.project, backend: backend)
        await #expect(throws: ToolDeniedError.self) {
            try await project.run(.local(.projectCreate), toolCallID: "call-2", arguments: .object(["template": "x/y", "name": "Clock"]), cancellation: nil, mcp: nil)
        }
        #expect(await backend.calls.isEmpty)
    }

    @Test
    func `General Chat's prompt says how to start a project`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let general = try SystemPrompt.make(project: generalChat(), projectRoot: home.projectURL.path, mode: .confirm, skills: [], mcpServers: [])
        #expect(general.contains("# General Chat"))
        #expect(general.contains("project_template_list"))
        let project = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .confirm, skills: [], mcpServers: [])
        #expect(!project.contains("# General Chat"))
    }
}
