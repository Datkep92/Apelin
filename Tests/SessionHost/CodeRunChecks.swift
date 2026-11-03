import ApelinCore
import ApelinProtocol
import Foundation

// code_run (Apelind/Session/Agent/AgentRunCode.swift, AgentApprovals.swift):
// a program the model wrote, handed to one interpreter of the one table
// (`RunCodeSpec.interpreters`) as mobile and in the session's project, under
// the bounds a shell_run has — the interpreter looked up on the run's PATH
// and refused by name when it is not there, the source's size and NUL bytes
// checked, the timeout range checked, the working directory kept inside the
// project — and never as root, which the agent refuses before it sends and
// the host refuses again.

func codeRunChecks(scratch: URL, scratchPath: String) async {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("code-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("code-approvals"))
    let sessions = AgentSessionTable.shared

    // A project of its own, with a directory inside it to run in.
    let projectRoot = scratch.appendingPathComponent("code-project")
    let projectPath = projectRoot.path
    let sources = projectRoot.appendingPathComponent("Sources").path
    try? FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: true)
    let project = ResolvedProject(id: "p-code", name: "Code", path: projectPath)
    let canonicalSources = CanonicalPath.resolve(sources) ?? sources

    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        await ledger.setMode(mode, session: id)
        return entry
    }
    func setMode(_ mode: ApprovalMode, _ id: String) async {
        await sessions.setMode(mode, session: id)
        await ledger.setMode(mode, session: id)
    }
    // What apelin-agent writes for a code_run approval: the script itself,
    // in the shape `RunCodeSpec` decodes from `detail.command`.
    let scriptJSON: (String, String) -> JSONValue = { interpreter, source in
        .object(["script": .object([
            "interpreter": .string(interpreter),
            "source": .string(source),
        ])])
    }
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        tool: String = "code_run",
        interpreter: String = "sh",
        source: String,
        sessionScope: Bool = false,
        workingDirectory: String = ".",
    ) async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string(tool),
            "workingDirectory": .string(workingDirectory),
            "allowsSessionScope": .bool(sessionScope),
            "detail": .object(["command": scriptJSON(interpreter, source)]),
        ]))
    }
    @discardableResult
    func approve(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        scope: ApprovalScope? = nil,
        ownerVerified: Bool? = true,
        workerTakesIt: Bool = true,
    ) async -> Bool {
        let request = AgentApproveRequest(
            sessionID: entry.sessionID,
            approvalID: approvalID,
            decision: .approve,
            scope: scope,
            ownerVerified: ownerVerified,
        )
        do {
            return try await AgentApprovals.relay(
                request,
                registry: registry,
                ledger: ledger,
                forward: { workerTakesIt },
                accepted: { $0 },
            )
        } catch {
            return false
        }
    }
    func request(
        _ spec: RunCodeSpec,
        in directory: String = ".",
        timeout: Int = 10,
        approval: RunCodeApproval = .relaxed,
        asRoot: Bool? = nil,
        session id: String = "code-session",
    ) -> AgentRunCodeRequest {
        AgentRunCodeRequest(
            sessionID: id,
            spec: spec,
            workingDirectory: directory,
            timeoutSeconds: timeout,
            approval: approval,
            asRoot: asRoot,
        )
    }
    func attempt(
        _ spec: RunCodeSpec,
        in directory: String = ".",
        timeout: Int = 10,
        as identity: AgentRunCode.Identity = .mobile(preset: nil),
    ) async throws -> AgentRunCodeResponse {
        try await AgentRunCode.run(
            request(spec, in: directory, timeout: timeout),
            as: identity,
            project: project,
            installRoot: "/",
            home: NSHomeDirectory(),
            stopsSeen: 0,
        )
    }
    func ran(
        _ spec: RunCodeSpec,
        in directory: String = ".",
        timeout: Int = 10,
        as identity: AgentRunCode.Identity = .mobile(preset: nil),
    ) async -> AgentRunCodeResponse? {
        try? await attempt(spec, in: directory, timeout: timeout, as: identity)
    }
    func refused(
        _ spec: RunCodeSpec,
        in directory: String = ".",
        timeout: Int = 10,
        as identity: AgentRunCode.Identity = .mobile(preset: nil),
    ) async -> String? {
        do {
            _ = try await attempt(spec, in: directory, timeout: timeout, as: identity)
            return nil
        } catch {
            return String(describing: error)
        }
    }
    func identity(
        _ entry: AgentSessionTable.Entry,
        _ spec: RunCodeSpec,
        _ approval: RunCodeApproval,
        asRoot: Bool? = nil,
        in directory: String = ".",
    ) async -> AgentRunCode.Identity? {
        let current = await sessions.entry(entry.sessionID) ?? entry
        return try? await AgentApprovals.authorize(
            request(spec, in: directory, approval: approval, asRoot: asRoot, session: entry.sessionID),
            entry: current,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    func trimmed(_ response: AgentRunCodeResponse?) -> String {
        (response?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Every interpreter in the table is handed its program its own way

    let environment = AgentRunCode.environment(
        preset: nil,
        project: project,
        installRoot: "/",
        home: NSHomeDirectory(),
    )
    let searched = AgentRunCode.searchPath(
        for: .mobile(preset: nil),
        environment: environment,
        installRoot: "/",
    )
    for interpreter in RunCodeSpec.interpreters {
        let spec = RunCodeSpec.script(interpreter: interpreter.name, source: "print(1)")
        if let found = AgentRunCode.findExecutable(interpreter.name, in: searched) {
            let command = try? AgentRunCode.invocation(
                spec,
                as: .mobile(preset: nil),
                environment: environment,
                installRoot: "/",
                directory: canonicalSources,
            )
            check(
                command?.executable == found && command?.argv == [found, interpreter.flag, "print(1)"],
                "\(interpreter.name) is handed its program as \(interpreter.flag), by its canonical path",
            )
        } else {
            // Not on this machine: refused by name, and nothing runs.
            let message = await refused(spec)
            check(
                message?.contains(interpreter.name) == true,
                "\(interpreter.name) is not on this PATH and is refused by name: \(message ?? "it ran")",
            )
        }
    }

    // MARK: An interpreter outside the table, a NUL byte, too much source

    let unknown = await refused(.script(interpreter: "ruby", source: "puts 1"))
    check(unknown?.contains("ruby") == true, "an interpreter outside the table is refused")
    check(
        unknown?.contains(RunCodeSpec.interpreterNames.joined(separator: ", ")) == true,
        "and the refusal lists the interpreters that are there",
    )
    let huge = await refused(
        .script(interpreter: "sh", source: String(repeating: "a", count: RunCodeSpec.maximumSourceBytes + 1)),
    )
    check(huge?.contains("256 KiB") == true, "source over the 256 KiB cap is refused")
    let nul = await refused(.script(interpreter: "sh", source: "echo a\u{0}b"))
    check(nul != nil, "a NUL byte in the source is refused")

    // MARK: The timeout, and the working directory

    for seconds in [0, RunCodeSpec.timeoutRange.upperBound + 1] {
        let message = await refused(.script(interpreter: "sh", source: "true"), timeout: seconds)
        check(message?.contains("1800") == true, "timeoutSeconds \(seconds) is refused")
    }
    let outside = await refused(.script(interpreter: "sh", source: "true"), in: "../..")
    check(outside != nil, "a working directory outside the project is refused")
    let missing = await refused(.script(interpreter: "sh", source: "true"), in: "Nowhere")
    check(missing != nil, "a working directory that is not a directory in the project is refused")

    // MARK: What actually runs, as mobile, in the project

    let hello = await ran(.script(interpreter: "sh", source: "echo hi"))
    check(hello?.exitCode == 0 && trimmed(hello) == "hi", "a script runs: echo hi printed hi")

    let status = await ran(.script(interpreter: "sh", source: "exit 3"))
    check(status?.exitCode == 3, "the script's own exit status comes back")

    let printedDirectory = await ran(.script(interpreter: "sh", source: "pwd -P"), in: "Sources")
    check(
        trimmed(printedDirectory) == canonicalSources,
        "a script runs in the working directory in the project: \(trimmed(printedDirectory))",
    )

    let named = await ran(.script(interpreter: "sh", source: "echo $APELIN_PROJECT_ROOT"))
    check(trimmed(named) == projectPath, "a script sees the project at APELIN_PROJECT_ROOT")

    let killed = await ran(.script(interpreter: "sh", source: "sleep 5"), timeout: 1)
    check(killed?.timedOut == true && killed?.exitCode == -1, "a script past its timeout is killed")

    let loud = await ran(.script(interpreter: "sh", source: "yes x | head -c 400000"), timeout: 60)
    let loudBytes = loud?.stdout.utf8.count ?? 0
    check(
        loud?.truncated == true && loudBytes >= 200_000 && loudBytes <= 256 * 1024,
        "past 256 KiB of output the run is cut short and says so: \(loudBytes) bytes",
    )

    // MARK: Never as root

    // The agent refuses `root: true` on a code_run before it sends it, and
    // the host refuses the interpreters again here. `sh` is the one name
    // both tables share — shell_run's own text mode — so a root `sh` script
    // is what a root shell_run with a pipeline looks like on this wire.
    let rootPython = await refused(.script(interpreter: "python3", source: "print(1)"), as: .root)
    check(
        rootPython?.contains("code_run never runs as root") == true,
        "python3 as root is refused, whatever the request said: \(rootPython ?? "it ran")",
    )
    let rootShell = await ran(.script(interpreter: "sh", source: "echo root-text"), as: .root)
    check(
        rootShell?.exitCode == 0 && trimmed(rootShell) == "root-text",
        "a root shell_run's own text still runs as root",
    )

    // MARK: What the host lets through under each mode

    let strict = await session("code-strict", mode: .confirm)
    let python = RunCodeSpec.script(interpreter: "python3", source: "print(1)")
    let preset = await identity(strict, python, .preset("ls"))
    check(preset == nil, "Strict runs no code_run on a preset")
    let sessionGrant = await identity(strict, python, .session)
    check(sessionGrant == nil, "and none on a session grant it never gave")
    await ask(strict, "code-card", source: "print(1)", interpreter: "python3")
    await approve(strict, "code-card")
    let byCard = await identity(strict, python, .user(approvalID: "code-card"))
    check(byCard == .mobile(preset: nil), "the app's approval of this script lets exactly it through, as mobile")

    // The card is for one script in one directory: another script, or the
    // same one elsewhere, is not what the user approved.
    let otherScript = await identity(
        strict,
        .script(interpreter: "python3", source: "print(2)"),
        .user(approvalID: "code-other"),
    )
    check(otherScript == nil, "an approval the session never asked for approves nothing")
    await ask(strict, "code-elsewhere", source: "print(1)", interpreter: "python3", workingDirectory: "Sources")
    await approve(strict, "code-elsewhere")
    let elsewhere = await identity(strict, python, .user(approvalID: "code-elsewhere"))
    check(elsewhere == nil, "a script approved in another working directory is not the one sent")

    // Root: a code_run card is no approval of a root request, and the
    // session grant of a script is no root grant either.
    await ask(strict, "code-root", source: "print(1)", interpreter: "python3")
    await approve(strict, "code-root")
    let rootAsCard = await identity(strict, python, .user(approvalID: "code-root"), asRoot: true)
    check(rootAsCard == nil, "a card for code_run authorises nothing as root")
    let rootAsGrant = await identity(strict, python, .session, asRoot: true)
    check(rootAsGrant == nil, "nor does the session grant of a script")

    // A card asked for by shell_run is a root approval; one asked for by
    // code_run never is.
    let codeAsked: JSONValue = .object([
        "tool": .string("code_run"),
        "detail": .object(["command": scriptJSON("sh", "echo hi")]),
    ])
    check(
        !AgentApprovals.isRootRequest(codeAsked),
        "a code_run card is never read as a root request",
    )

    // Full mode: nothing asks, and a code_run is still mobile.
    let full = await session("code-full", mode: .full)
    let relaxed = await identity(full, python, .relaxed)
    check(relaxed == .mobile(preset: nil), "Full runs a code_run as mobile, with no card")
    await setMode(.confirm, "code-full")
}
