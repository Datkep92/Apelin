@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import enum ApelinProtocol.RunCodeSpec
import Foundation
import KWWKAI
import Testing

/// code_run from the agent's side: a program the model wrote, for one
/// interpreter, as mobile, in the project — never a command line and never
/// root. The session host runs the same table and checks the same fields
/// (`AgentRunCodeChecks`); these pin that the two halves describe one call.
@Suite("code_run")
struct CodeRunToolTests {
    /// The tool's schema and sentence offer exactly the interpreters the host
    /// looks up, and nothing that could ask for root.
    @Test
    func `the tool offers exactly the interpreters the host runs`() {
        let fields = AgentToolName.codeRun.parameters.objectValue
        let properties = fields?["properties"]?.objectValue
        let offered = properties?["interpreter"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue)
        #expect(offered == RunCodeSpec.interpreterNames)
        #expect(fields?["required"]?.arrayValue?.compactMap(\.stringValue) == ["source"])
        #expect(properties?["argv"] == nil && properties?["command"] == nil, "no command line here")
        #expect(properties?["root"] == nil, "there is no root here at all")
        #expect(AgentToolName.codeRun.summary.contains(RunCodeSpec.interpreterNames.joined(separator: ", ")))
    }

    /// Every shape the model may write arrives at the host as one `.script`
    /// invocation for the interpreter it names, as mobile, in the project.
    @Test
    func `a program is sent as one script for the interpreter it names`() async throws {
        let cases: [(arguments: JSONValue, invocation: RunCodeInvocation)] = [
            (["source": "print(1)"], .script(interpreter: "python3", source: "print(1)")),
            (["source": "print(1)", "interpreter": "node"], .script(interpreter: "node", source: "print(1)")),
            (["code": "id -u", "interpreter": "sh"], .script(interpreter: "sh", source: "id -u")),
            (["source": "print $0", "interpreter": "perl"], .script(interpreter: "perl", source: "print $0")),
            (["source": "echo hello", "cwd": "Sources"], .script(interpreter: "python3", source: "echo hello")),
        ]
        for (arguments, invocation) in cases {
            let harness = try DigestApprovalTests.Harness(mode: .relaxed)
            defer { harness.home.remove() }
            let (_, asked) = try await harness.run(.codeRun, arguments)
            #expect(asked.isEmpty, "\(arguments)")
            let sent = await harness.backend.runCodeRequests
            #expect(sent.count == 1, "\(arguments)")
            #expect(sent.first?.invocation == invocation, "\(arguments)")
            #expect(sent.first?.workingDirectory == (arguments.argString("cwd") ?? "."), "\(arguments)")
            #expect(sent.first?.asRoot == false, "\(arguments): a program is mobile")
            #expect(sent.first?.context.approval == .relaxed, "\(arguments)")
        }
    }

    /// Strict asks each time, with the source and the interpreter on the
    /// card, and never offers "for this session": a program written now is
    /// not a preset call, and the next one is another program.
    @Test
    func `Strict asks each time and never for the session`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let expected = RunCodeInvocation.script(interpreter: "python3", source: "print(1)")
        for round in 0 ..< 2 {
            let (_, asked) = try await harness.run(.codeRun, ["source": "print(1)"])
            #expect(asked.count == 1, "round \(round)")
            let card = asked.first
            #expect(card?.detail == .command(expected), "round \(round): \(String(describing: card?.detail))")
            #expect(card?.allowsSessionScope == false, "round \(round)")
            #expect(card?.workingDirectory == ".")
            let shown = try JSONDecoder().decode(JSONValue.self, from: Data((card?.arguments ?? "").utf8)).objectValue
            #expect(shown?["source"] == .string("print(1)"), "the card shows the program")
            let sent = await harness.backend.runCodeRequests
            #expect(sent.count == round + 1)
        }
    }

    /// Nothing here runs as root: a call that asks for it is refused and told
    /// where to go, in every mode, and the odd shapes the model writes for
    /// "yes" mean mobile here as they do for `shell_run`.
    @Test
    func `a call that asks for root is refused, in every mode`() async throws {
        let mobile: [JSONValue] = [
            ["source": "print(1)", "root": false],
            ["source": "print(1)", "root": "true"],
            ["source": "print(1)", "root": 1],
            ["source": "print(1)", "root": .null],
        ]
        for mode in [ApprovalMode.confirm, .relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            await #expect(throws: ToolArgumentError.self) {
                _ = try await harness.run(.codeRun, ["source": "print(1)", "root": true])
            }
            for shape in mobile {
                _ = try await harness.run(.codeRun, shape)
            }
            let sent = await harness.backend.runCodeRequests
            #expect(sent.count == mobile.count, "\(mode): only the root call was refused: \(sent.count)")
            #expect(sent.allSatisfy { !$0.asRoot }, "\(mode)")
        }
    }

    /// A call that is not a program for one interpreter is refused by name,
    /// before the user is asked anything.
    @Test
    func `what is not a program for one interpreter is refused`() async throws {
        let tooLong = String(repeating: "a", count: RunCodeSpec.maximumSourceBytes + 1)
        let cases: [JSONValue] = [
            [:],
            ["source": ""],
            ["source": "  \n\t "],
            ["source": "print(1)", "code": "print(2)"],
            ["source": "print(1)", "argv": ["ls"]],
            ["source": "print(1)", "command": "ls -l"],
            ["source": "print(1)", "script": "print(1)"],
            ["source": "print(1)", "interpreter": "ruby"],
            ["source": "print(1)", "interpreter": ""],
            ["source": "a\u{0}b"],
            ["source": tooLong],
        ]
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        for arguments in cases {
            await #expect(throws: ToolArgumentError.self) {
                _ = try await harness.run(.codeRun, arguments)
            }
        }
        let sent = await harness.backend.runCodeRequests
        #expect(sent.isEmpty, "nothing reached the host: \(sent)")
    }

    /// The timeout is clamped to the range the tool publishes and the host
    /// accepts, and the default is 120 seconds.
    @Test
    func `the timeout is clamped to what the host accepts`() async throws {
        let cases: [(arguments: JSONValue, seconds: Int)] = [
            (["source": "print(1)"], 120),
            (["source": "print(1)", "timeout_seconds": 7], 7),
            (["source": "print(1)", "timeout_seconds": 1], 1),
            (["source": "print(1)", "timeout_seconds": 0], 1),
            (["source": "print(1)", "timeout_seconds": 1800], 1800),
            (["source": "print(1)", "timeout_seconds": 99_999], 1800),
        ]
        for (arguments, seconds) in cases {
            let harness = try DigestApprovalTests.Harness(mode: .relaxed)
            defer { harness.home.remove() }
            _ = try await harness.run(.codeRun, arguments)
            let sent = await harness.backend.runCodeRequests
            #expect(sent.first?.timeoutSeconds == seconds, "\(arguments)")
        }
    }

    /// Leaving the project is refused in every mode; it is outside the tool's
    /// capability rather than a matter of asking.
    @Test
    func `a working directory outside the project is refused`() async throws {
        for cwd in ["../..", "~", "/tmp"] {
            let harness = try DigestApprovalTests.Harness(mode: .relaxed)
            defer { harness.home.remove() }
            await #expect(throws: (any Error).self) {
                _ = try await harness.run(.codeRun, ["source": "print(1)", "cwd": cwd])
            }
            #expect(await harness.backend.runCodeRequests.isEmpty, "\(cwd)")
        }
    }

    /// A program that names icli asks about the screen as well, in every
    /// mode, while Ask Before Using the Screen is on.
    @Test
    func `a program that names icli asks about the screen`() async throws {
        let source = "import subprocess; subprocess.run([\"icli\", \"url\", \"open\", \"x\"])"
        let expected = RunCodeInvocation.script(interpreter: "python3", source: source)
        for mode in [ApprovalMode.confirm, .relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let (_, asked) = try await harness.run(.codeRun, ["source": source])
            #expect(asked.count == 1, "\(mode)")
            #expect(asked.first?.detail == .screenControl(.command(expected, asRoot: false)), "\(mode)")
        }
    }
}