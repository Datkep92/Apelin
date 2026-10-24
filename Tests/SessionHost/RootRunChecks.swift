import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// shell_run as root (Apelind/Session/Agent/AgentApprovals.swift,
// AgentRunCode.swift): Full mode runs it; Strict and Relaxed run it only
// with one approval the app gave, with the owner checked, for exactly that
// root request; an approval of an ordinary request, a session grant, a
// preset or a closed session never does; and what the banner and the run's
// environment say about it.

func rootRunChecks(scratch: URL, scratchPath: String) async {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("root-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("root-approvals"))
    let sessions = AgentSessionTable.shared

    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-root", name: "Root", path: scratchPath),
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
    let install = ["irisin-cli", "install", "--yes", "mobilesubstrate"]
    let argv: (([String]) -> JSONValue) = { .object(["argv": .object(["_0": .array($0.map { .string($0) })])]) }
    // What apelin-agent writes for a root request (`rootCommand`) or an
    // ordinary one (`command`).
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        _ words: [String],
        root: Bool,
        sessionScope: Bool = false,
        workingDirectory: String = ".",
    ) async {
        let key = root ? RunCodeApproval.rootCommandDetail : "command"
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string("shell_run"),
            "workingDirectory": .string(workingDirectory),
            "allowsSessionScope": .bool(sessionScope),
            "detail": .object([key: argv(words)]),
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
    func identity(
        _ entry: AgentSessionTable.Entry,
        _ words: [String],
        _ approval: RunCodeApproval,
        root: Bool = true,
        in directory: String = ".",
    ) async -> AgentRunCode.Identity? {
        let run = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(words),
            workingDirectory: directory,
            approval: approval,
            asRoot: root ? true : nil,
        )
        let current = await sessions.entry(entry.sessionID) ?? entry
        return try? await AgentApprovals.authorize(
            run,
            entry: current,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    func kept(_ entry: AgentSessionTable.Entry, _ approvalID: String) async -> Bool {
        await sessions.entry(entry.sessionID)?.approvals[approvalID] == .approve
    }

    // MARK: Strict: nothing runs as root without the approval of that root request

    let strict = await session("root-strict", mode: .confirm)
    for evidence: RunCodeApproval in [.relaxed, .preset("ls"), .session, .user(approvalID: "never-asked")] {
        let ran = await identity(strict, ["ls"], evidence)
        check(ran == nil, "Strict runs nothing as root on \(evidence)")
    }
    await ask(strict, "plain", install, root: false)
    await approve(strict, "plain")
    let plainForRoot = await identity(strict, install, .user(approvalID: "plain"))
    check(plainForRoot == nil, "an approval of the command as mobile is no approval of it as root")
    let plainKept = await kept(strict, "plain")
    check(plainKept, "and is left as the app gave it")

    await ask(strict, "root-1", install, root: true)
    let unverified = await approve(strict, "root-1", ownerVerified: nil)
    check(!unverified, "an approval of a root request without the owner checked is refused")
    let unverifiedKept = await kept(strict, "root-1")
    check(!unverifiedKept, "and records nothing")
    let refusedOwner = await approve(strict, "root-1", ownerVerified: false)
    check(!refusedOwner, "nor with the check said to have failed")
    let denied = AgentApproveRequest(sessionID: strict.sessionID, approvalID: "root-1", decision: .deny)
    let denyPassed = await (try? AgentApprovals.relay(
        denied,
        registry: registry,
        ledger: ledger,
        forward: { true },
        accepted: { $0 },
    )) ?? false
    check(denyPassed, "denying a root request needs no check")

    await ask(strict, "root-2", install, root: true)
    await approve(strict, "root-2")
    let otherCommand = await identity(strict, ["irisin-cli", "remove", "--yes", "mobilesubstrate"], .user(approvalID: "root-2"))
    check(otherCommand == nil, "a root approval runs no other command")
    let otherDirectory = await identity(strict, install, .user(approvalID: "root-2"), in: "Sources")
    check(otherDirectory == nil, "nor in another working directory")
    let asMobile = await identity(strict, install, .user(approvalID: "root-2"), root: false)
    check(asMobile == nil, "nor the same command as mobile")
    let stillKept = await kept(strict, "root-2")
    check(stillKept, "none of those spends it")
    let approved = await identity(strict, install, .user(approvalID: "root-2"))
    check(approved == .root, "the approved root request runs as root")
    let again = await identity(strict, install, .user(approvalID: "root-2"))
    check(again == nil, "once")

    // MARK: Never under a session grant

    await ask(strict, "root-session", install, root: true, sessionScope: true)
    await approve(strict, "root-session", scope: .session)
    let grants = await sessions.entry(strict.sessionID)?.runCodeGrants ?? []
    check(grants.isEmpty, "a root request approved for the session leaves no session grant")
    await ask(strict, "mobile-session", install, root: false, sessionScope: true)
    await approve(strict, "mobile-session", scope: .session)
    let mobileGrant = await identity(strict, install, .session, root: false)
    check(mobileGrant == .mobile(preset: nil), "a session grant runs its command as mobile")
    let rootGrant = await identity(strict, install, .session)
    check(rootGrant == nil, "and never as root")

    // MARK: Taken back when the worker does not accept the relay

    await ask(strict, "root-refused", install, root: true)
    await approve(strict, "root-refused", workerTakesIt: false)
    let refusedRelay = await identity(strict, install, .user(approvalID: "root-refused"))
    check(refusedRelay == nil, "a root approval the worker did not accept runs nothing")

    // MARK: Relaxed asks for root too

    let relaxed = await session("root-relaxed", mode: .relaxed)
    let relaxedPlain = await identity(relaxed, install, .relaxed, root: false)
    check(relaxedPlain == .mobile(preset: nil), "Relaxed runs an ordinary call as mobile")
    let relaxedRoot = await identity(relaxed, install, .relaxed)
    check(relaxedRoot == nil, "but nothing as root without asking")
    await ask(relaxed, "relaxed-root", install, root: true)
    await approve(relaxed, "relaxed-root")
    let relaxedApproved = await identity(relaxed, install, .user(approvalID: "relaxed-root"))
    check(relaxedApproved == .root, "an approved root request runs under Relaxed")

    // MARK: Full runs root without asking, by both records of the mode

    let full = await session("root-full", mode: .full)
    let fullRoot = await identity(full, install, .relaxed)
    check(fullRoot == .root, "Full runs a root request without asking")
    let fullPlain = await identity(full, ["make"], .relaxed, root: false)
    check(fullPlain == .mobile(preset: nil), "and an ordinary one as mobile, as Relaxed does")
    await ledger.setMode(.confirm, session: full.sessionID)
    let ledgerDisagrees = await identity(full, install, .relaxed)
    check(ledgerDisagrees == nil, "the session table alone saying Full is not enough")
    await ledger.forgetSession(full.sessionID)
    let ledgerForgot = await identity(full, install, .relaxed)
    check(ledgerForgot == nil, "nor with the ledger not knowing the session")

    // A mode change mid-session applies to the next call.
    await setMode(.full, full.sessionID)
    let backToFull = await identity(full, install, .relaxed)
    check(backToFull == .root, "Full again runs root")
    await setMode(.confirm, full.sessionID)
    let leftFull = await identity(full, install, .relaxed)
    check(leftFull == nil, "leaving Full stops root without asking at once")
    await setMode(.relaxed, full.sessionID)
    let relaxedNow = await identity(full, install, .relaxed)
    check(relaxedNow == nil, "and so does Relaxed")

    // MARK: Forgotten on close, and nothing for an ended session

    let closing = await session("root-closing", mode: .confirm)
    await ask(closing, "root-close", install, root: true)
    await approve(closing, "root-close")
    await sessions.forgetGrants(closing.sessionID)
    let afterClose = await identity(closing, install, .user(approvalID: "root-close"))
    check(afterClose == nil, "a root approval not spent is forgotten when the session closes")

    let ended = await session("root-ended", mode: .full)
    await registry.finish(ended.task.taskID, .succeeded, message: "closed")
    let endedRoot = await identity(ended, install, .relaxed)
    check(endedRoot == nil, "a session whose task ended runs nothing as root, even in Full")
    let endedPlain = await identity(ended, ["make"], .relaxed, root: false)
    check(endedPlain == .mobile(preset: nil), "the ended-task check is root's alone")

    // MARK: The banner names a root request

    var track = AgentNoticeTrack(sessionID: "0b9d3c1e-6a64-4c2f-9d3e-2f1a7c5b8e11")
    let rootNotice = track.take("approvalRequested", payload: .object([
        "approvalID": .string("r"),
        "tool": .string("shell_run"),
        "reason": .string("Runs as root."),
        "detail": .object([RunCodeApproval.rootCommandDetail: argv(install)]),
    ]), title: "Install", posted: AgentNoticeMarks())
    check(rootNotice?.subtitle == .key("Root Approval Required"), "a root request's banner says so")
    let plainNotice = track.take("approvalRequested", payload: .object([
        "approvalID": .string("p"),
        "tool": .string("shell_run"),
        "detail": .object(["command": argv(install)]),
    ]), title: "Install", posted: AgentNoticeMarks())
    check(plainNotice?.subtitle == .key("Approval Required"), "an ordinary request's banner does not")

    // MARK: What a run as root sees, and that it runs

    let project = ResolvedProject(id: "p-root", name: "Root", path: scratchPath)
    let mobileHome = "/var/mobile"
    let rootEntries = AgentRunCode.environment(
        preset: nil,
        project: project,
        installRoot: "/",
        home: mobileHome,
        asRoot: true,
    )
    check(rootEntries.contains("HOME=\(AgentRunCode.rootHome)"), "a run as root has root's own HOME")
    check(!rootEntries.contains("HOME=\(mobileHome)"), "and not mobile's")
    check(rootEntries.contains("APELIN_PROJECT_ROOT=\(scratchPath)"), "in the same project")
    let mobileEntries = AgentRunCode.environment(preset: nil, project: project, installRoot: "/", home: mobileHome)
    check(mobileEntries.contains("HOME=\(mobileHome)"), "a run as mobile keeps mobile's HOME")

    // On the Mac the host is not root, so `.root` runs as this user: what
    // is checked here is that the root path spawns at all, unchanged in
    // its bounds; that it is uid 0 on a device is Device-Validation's.
    let response = try? await AgentRunCode.run(
        AgentRunCodeRequest(sessionID: "root-run", spec: .argv(["id", "-u"]), timeoutSeconds: 10, approval: .relaxed, asRoot: true),
        as: .root,
        project: project,
        installRoot: "/",
        home: NSHomeDirectory(),
        stopsSeen: AgentRunCode.stopCount(session: "root-run"),
    )
    check(
        response?.exitCode == 0 && response?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == String(geteuid()),
        "a root run runs as the host itself, without dropping to mobile: \(String(describing: response))",
    )
}
