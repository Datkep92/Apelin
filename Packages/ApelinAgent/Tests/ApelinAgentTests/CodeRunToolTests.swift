@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import enum ApelinProtocol.RunCodeSpec
import Foundation
import KWWKAI
import Testing

/// code_run from the agent's side: a program the model wrote, for one
/// interpreter, in the project — never a command line. It runs as mobile
/// unless the call asks for root, which is the user's to give exactly as it
/// is for `shell_run`. The session host runs the same table and checks the
/// same fields (`AgentRunCodeChecks`); these pin that the two halves describe
/// one call.
@Suite("code_run")
struct CodeRunToolTests {
    /// The tool's schema and sentence offer exactly the interpreters the host
    /// looks up, and say root is the user's to give where it is passed.
    @Test
    func `the tool offers exactly the interpreters the host runs`() {
        let fields = AgentToolName.codeRun.parameters.objectValue
        let properties = fields?["properties"]?.objectValue
        let offered = properties?["interpreter"]?.objectValue?["enum"]?.stringList
        #expect(offered == RunCodeSpec.interpreterNames)
        #expect(fields?["required"]?.stringList == ["source"])
        #expect(properties?["argv"] == nil && properties?["command"] == nil, "no command line here")
        #expect(properties?["root"]?.objectValue?["type"] == .string("boolean"), "root is offered, and is the user's to give")
        #expect(AgentToolName.codeRun.summary.contains("root: true runs the program as root"), "the sentence says what root does")
        #expect(AgentToolName.codeRun.summary.contains(RunCodeSpec.interpreterNames.joined(separator: ", ")))
    }

    /// Every shape the model may write arrives at the host as one `.script`
    /// invocation for the interpreter it names, in the project, mobile
    /// unless the call asks for root.
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

    /// A call that asks for root is the user's to give, exactly as `shell_run`'s
    /// is: the card names this program and this directory, and the odd shapes
    /// the model writes for "yes" mean mobile here as they do there.
    @Test
    func `a call that asks for root asks the user, and is read as shell_run reads it`() async throws {
        let mobile: [JSONValue] = [
            ["source": "print(1)", "root": false],
            ["source": "print(1)", "root": "true"],
            ["source": "print(1)", "root": 1],
            ["source": "print(1)", "root": .null],
        ]
        for mode in [ApprovalMode.confirm, .relaxed] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let invocation = RunCodeInvocation.script(interpreter: "python3", source: "print(1)")
            let (_, asked) = try await harness.run(.codeRun, ["source": "print(1)", "root": true])
            #expect(asked.count == 1, "\(mode): one card")
            guard let card = asked.first else { continue }
            #expect(card.detail == .rootCommand(invocation), "\(mode): \(card.detail)")
            #expect(card.allowsSessionScope == false, "a root card never offers the session")
            let shown = try JSONDecoder().decode(JSONValue.self, from: Data(card.arguments.utf8)).objectValue
            #expect(shown?["root"] == .bool(true), "the card's arguments say root")
            let sent = await harness.backend.runCodeRequests
            #expect(sent.count == 1, "\(mode): the approved call ran")
            #expect(sent.first?.invocation == invocation, "\(mode)")
            #expect(sent.first?.asRoot == true, "\(mode)")
            guard case let .user(requestID, _)? = sent.first?.context.approval else {
                Issue.record("\(mode): moved without the user's approval"); continue
            }
            #expect(requestID == card.id, "\(mode): sent with this card's approval")
            for shape in mobile {
                _ = try await harness.run(.codeRun, shape)
            }
            let after = await harness.backend.runCodeRequests
            #expect(after.count == mobile.count + 1, "\(mode): every call ran: \(after.count)")
            #expect(after.dropFirst().allSatisfy { !$0.asRoot }, "\(mode): \(after)")
        }

        let full = try DigestApprovalTests.Harness(mode: .full)
        defer { full.home.remove() }
        let (_, inFull) = try await full.run(.codeRun, ["source": "print(1)", "root": true])
        #expect(inFull.isEmpty, "Full asks nothing")
        let rootSent = await full.backend.runCodeRequests
        #expect(rootSent.count == 1)
        #expect(rootSent.first?.asRoot == true, "Full still sends the root request")
        #expect(rootSent.first?.context.approval == .relaxed, "evidence the host does not take as approval")
    }

    /// A call that is not a program for one interpreter is refused by name,
    /// before the user is asked anything. An `interpreter` left empty is not a
    /// name at all: empty arguments are dropped before a tool sees them, so
    /// the default interpreter runs.
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
            ["source": "a\u{0}b"],
            ["source": .string(tooLong)],
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
                _ = try await harness.run(.codeRun, ["source": "print(1)", "cwd": .string(cwd)])
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
            let (_, asked) = try await harness.run(.codeRun, ["source": .string(source)])
            #expect(asked.count == 1, "\(mode)")
            #expect(asked.first?.detail == .screenControl(.command(expected, asRoot: false)), "\(mode)")
        }
    }
}

/// The tool's published schema is `JSONValue`, which carries an `objectValue`
/// and a subscript but no array accessor; a list of strings is read here.
private extension JSONValue {
    var stringList: [String]? {
        guard case let .array(values) = self else { return nil }
        return values.compactMap { value in
            if case let .string(text) = value { return text }
            return nil
        }
    }
}