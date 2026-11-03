@testable import ApelinProtocol
import XCTest

/// The one table of interpreters both run tools read: the tool's description,
/// the agent's own check and the session host's lookup all come from it, so a
/// name `code_run` offers is one the host runs, and one it refuses is in no
/// description.
final class RunCodeSpecTests: XCTestCase {
    func testEachInterpreterIsAPlainNameAndOneFlag() {
        let names = RunCodeSpec.interpreters.map(\.name)
        XCTAssertEqual(names, RunCodeSpec.interpreterNames)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        for interpreter in RunCodeSpec.interpreters {
            XCTAssertFalse(interpreter.name.isEmpty)
            XCTAssertFalse(interpreter.name.contains("/"), "\(interpreter.name) is a path, so PATH finds nothing")
            XCTAssertEqual(interpreter.name, interpreter.name.lowercased(), interpreter.name)
            XCTAssertTrue(
                interpreter.name.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) },
                "\(interpreter.name) is not a plain executable name",
            )
            XCTAssertTrue(interpreter.flag.hasPrefix("-"), interpreter.flag)
            XCTAssertFalse(interpreter.flag.contains(where: \.isWhitespace), "\(interpreter.flag) is more than a flag")
        }
        XCTAssertTrue(names.contains(RunCodeSpec.defaultInterpreter), RunCodeSpec.defaultInterpreter)
        XCTAssertEqual(names.first, "sh", "the order a refusal lists them in")
    }

    func testTheLimitsAreTheOnesTheToolAndTheHostPublish() {
        XCTAssertEqual(RunCodeSpec.timeoutRange, 1 ... 1800)
        XCTAssertEqual(RunCodeSpec.timeoutRange.lowerBound, 1)
        XCTAssertEqual(RunCodeSpec.timeoutRange.upperBound, 1800)
        XCTAssertEqual(RunCodeSpec.maximumSourceBytes, 256 * 1024)
    }

    func testEachSpecSurvivesTheWire() throws {
        for interpreter in RunCodeSpec.interpreters {
            let script = RunCodeSpec.script(interpreter: interpreter.name, source: "print(\"hi\")")
            let decoded = try JSONDecoder().decode(RunCodeSpec.self, from: try JSONEncoder().encode(script))
            XCTAssertEqual(decoded, script)
        }
        let argv = RunCodeSpec.argv(["/bin/ls", "-l"])
        let plain = try JSONDecoder().decode(RunCodeSpec.self, from: try JSONEncoder().encode(argv))
        XCTAssertEqual(plain, argv)
        XCTAssertNotEqual(plain, RunCodeSpec.script(interpreter: "sh", source: "/bin/ls -l"))
    }

    func testARunAsksForTheProjectAndMobileByDefault() {
        let request = AgentRunCodeRequest(
            sessionID: "session",
            spec: .script(interpreter: RunCodeSpec.defaultInterpreter, source: "print(1)"),
            approval: .user(approvalID: "approval"),
        )
        XCTAssertEqual(AgentRunCodeRequest.operation, .agentRunCode)
        XCTAssertEqual(request.workingDirectory, ".")
        XCTAssertEqual(request.timeoutSeconds, 120)
        XCTAssertNil(request.asRoot, "a run is mobile unless it says otherwise")
        XCTAssertEqual(request.spec, .script(interpreter: "python3", source: "print(1)"))
        XCTAssertEqual(request.approval, .user(approvalID: "approval"))
    }
}