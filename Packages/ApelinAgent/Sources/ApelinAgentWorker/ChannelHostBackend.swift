import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `AgentHostBackend` over `ApelinService`: every system tool the agent has
/// is one request to the session host, through the same typed facade the app
/// and the console use. In `apelin-agent` the transport is the worker
/// channel (`ChannelTransport`); tests pass a fake.
///
/// Mapping (tool → host operation):
/// apelin_project_build → `buildStart`, then its task read to the end;
/// apelin_package_install → `installPackage` likewise; apelin_package_remove →
/// `removePackage`; apelin_device_respring → `respring`; apelin_package_confirm_loaded → a `confirmLoaded` task with the session's
/// project (and `trigger: respring` when asked), read to its end, the image
/// list never asked for;
/// apelin_log_read → a bounded `logStream` read to its end; apelin_crash_list →
/// `crashList`; apelin_crash_read → `crashOpen` (a read-only descriptor);
/// apelin_crash_symbolicate → `crashSymbolicate` (apelin-diagnostics, the project's
/// dSYMs); apelin_screen_capture / apelin_screen_read_tree / apelin_screen_interact → `captureScreen` /
/// `readUITree` / `uiAction`; apelin_sdk_analyze_framework and apelin_sdk_read_header's SDK →
/// `sdkList`, the project's pinned SDK first; shell_run → `agentRunCode`,
/// which the host runs as mobile in the project (as root, with `asRoot`, when
/// Full mode or the user's approval of that root request lets it); apelin_template_list →
/// `extensionList`, isolated extensions left out; apelin_project_create →
/// `projectCreate`; git_status / git_diff / git_stage / git_unstage /
/// git_commit, git_init → `gitStatus` / `gitDiff` / `gitStage` /
/// `gitUnstage` / `gitCommit` / `gitInit` on the session's project (no
/// author: the host's settings);
/// git_fetch / git_pull / git_push / git_clone → `gitFetch` / `gitPull` /
/// `gitPush` / `gitCloneInto`, each task read to its end;
/// apelin_conversation_create → `agentOpen` with this session's provider, model
/// and effort, in this session's project or the one named, answered
/// without waiting; apelin_conversation_send → `agentPrompt` with the text alone;
/// apelin_conversation_list → `agentList` of a project; apelin_conversation_read →
/// `agentList` for the task, then `agentAttach` (`ConversationReader`);
/// apelin_conversation_stop → `agentAbort`, then `agentClose` when asked. The host
/// keeps them to this session's project, and to another one only as the
/// user approved. apelin_toolchain_list, apelin_sdk_list, apelin_toolchain_setup,
/// apelin_toolchain_self_test, apelin_sdk_import and apelin_project_set_environment's check:
/// ChannelHostBackend+Environment.
public struct ChannelHostBackend: AgentHostBackend {
    public let service: ApelinService
    public let sessionID: String
    public let project: ApelinAgent.ProjectIdentity
    /// `Projects/<name>`, read for the pinned SDK.
    public let projectURL: URL
    /// `Projects/`, where a conversation call finds the other project it names.
    public let projectsURL: URL
    /// What the session runs with now, which apelin_conversation_create passes on.
    public let modelChoice: SessionModelChoice

    public static let maximumScreenshotBytes = 4 * 1024 * 1024
    static let logExcerptBytes = 8 * 1024
    /// git_diff hands the model at most this much; a path narrows it.
    public static let maximumDiffBytes = 64 * 1024

    /// apelin_conversation_read hands the model at most this much text.
    public static let maximumConversationBytes = 32 * 1024
    /// One attach while apelin_conversation_read waits: short, so a stop is quick.
    static let conversationPollMilliseconds = 5000

    public init(
        service: ApelinService,
        sessionID: String,
        project: ApelinAgent.ProjectIdentity,
        projectURL: URL,
        projectsURL: URL? = nil,
        modelChoice: SessionModelChoice = SessionModelChoice(),
    ) {
        self.service = service
        self.sessionID = sessionID
        self.project = project
        self.projectURL = projectURL
        self.projectsURL = projectsURL ?? projectURL.deletingLastPathComponent()
        self.modelChoice = modelChoice
    }

    // MARK: shell_run

    public func runCode(_ request: RunCodeRequest) async throws -> RunCodeResponse {
        let response: AgentRunCodeResponse
        do {
            response = try await service.agentRunCode(AgentRunCodeRequest(
                sessionID: sessionID,
                spec: Self.spec(request.invocation),
                workingDirectory: request.workingDirectory,
                timeoutSeconds: request.timeoutSeconds,
                approval: Self.approval(request.context.approval),
                asRoot: request.asRoot ? true : nil,
            ))
        } catch let error as ApelinError where error.code == .denied && error.reason == .notAPreset {
            // The host's preset rule does not count this call; the runner
            // asks the user instead.
            throw HostRefusedPresetError(message: error.message)
        }
        return RunCodeResponse(
            exitCode: response.exitCode,
            stdout: response.stdout,
            stderr: response.timedOut
                ? response.stderr + "\n[killed after \(request.timeoutSeconds) s]"
                : response.stderr,
            truncated: response.truncated,
            durationMilliseconds: response.durationMilliseconds,
        )
    }

    static func spec(_ invocation: RunCodeInvocation) -> RunCodeSpec {
        switch invocation {
        case let .argv(argv): .argv(argv)
        case let .shell(text): .script(interpreter: "sh", source: text)
        case let .script(interpreter, source): .script(interpreter: interpreter, source: source)
        }
    }

    static func approval(_ evidence: ApprovalEvidence) -> RunCodeApproval {
        switch evidence {
        case let .preset(name): .preset(name)
        case let .user(requestID, _):
            requestID == ApprovalEvidence.sessionRequestID ? .session : .user(approvalID: requestID)
        // The host decides from the session's mode; anything else is not
        // evidence for running code.
        case .relaxed, .notRequired, .templateMatch, .digestApproved: .relaxed
        }
    }

    // MARK: build, install, remove, respring

    public func build(_ request: BuildRequest) async throws -> BuildResponse {
        let configuration: ApelinProtocol.BuildConfiguration = request.configuration == .release ? .release : .debug
        let bootstrap = try Self.bootstrap(request.bootstrap)
        // A distribution build reports what the package should not carry yet.
        let check = await configuration == .release && bootstrap != nil
            ? (try? distributionCheck(bootstrap: bootstrap))
            : nil
        let warnings = (check?.diagnostics ?? []).filter(Self.isDistributionWarning).map(Self.diagnostic)
        let handle = try await service.buildStart(
            projectID: project.id,
            configuration: configuration,
            bootstrap: bootstrap,
        )
        var buildID = handle.taskID.rawValue
        var diagnostics = warnings
        var artifacts: [ApelinAgent.BuildArtifact] = []
        var log = BoundedTail(limit: Self.logExcerptBytes)
        let end = try await read(handle) { event in
            switch event.kind {
            case "diagnostic":
                if let diagnostic = try? event.payload?.decode(ProjectDiagnostic.self) {
                    diagnostics.append(Self.diagnostic(diagnostic))
                }
            case "artifact":
                if let artifact = try? event.payload?.decode(ApelinProtocol.BuildArtifact.self) {
                    let file = artifact.path.map { ($0 as NSString).lastPathComponent }
                    let bootstrap = artifact.bootstrap.map { "_\($0)" } ?? ""
                    artifacts.append(ApelinAgent.BuildArtifact(
                        id: artifact.artifactID,
                        kind: .package,
                        name: file ?? "\(artifact.packageID)_\(artifact.version)\(bootstrap).deb",
                        digest: artifact.digest,
                    ))
                    // The artifact names the APELIN_BUILD_ID apelin_package_confirm_loaded matches.
                    if let named = artifact.buildID, !named.isEmpty {
                        buildID = named
                    }
                }
            case "log":
                if let line = event.payload?["line"]?.stringValue {
                    log.append(line)
                }
            default:
                break
            }
            // Another event may name the APELIN_BUILD_ID before an artifact does.
            if event.kind != "artifact", buildID == handle.taskID.rawValue,
               let named = event.payload?["buildID"]?.stringValue, !named.isEmpty
            {
                buildID = named
            }
        }
        if let message = end.message {
            log.append(message)
        }
        return BuildResponse(
            buildID: buildID,
            succeeded: end.state == .succeeded,
            diagnostics: diagnostics,
            artifacts: artifacts,
            logExcerpt: log.text,
        )
    }

    // MARK: distribution

    /// What stops the build counts as well as what the package should not
    /// carry: a project whose check fails is not ready either. A workspace
    /// has no description to read before its script runs, so its release
    /// build checks the package instead, as the note says.
    public func checkDistribution(_ request: DistributionCheckRequest) async throws -> DistributionCheckResponse {
        let check = try await distributionCheck(bootstrap: Self.bootstrap(request.bootstrap))
        let issues = check.diagnostics.filter { $0.severity == .error || Self.isDistributionWarning($0) }
            .map(Self.diagnostic)
        return DistributionCheckResponse(
            ready: issues.isEmpty,
            issues: issues,
            note: check.buildSystem == .external
                ? "This workspace's package is checked when its build script writes it: a release build lists what it finds among its diagnostics."
                : nil,
        )
    }

    /// The bootstrap a request names, or nil when it names none.
    static func bootstrap(_ raw: String?) throws -> ApelinProtocol.BuildBootstrap? {
        let bootstrap = raw.flatMap(ApelinProtocol.BuildBootstrap.init(rawValue:))
        guard raw == nil || bootstrap != nil else {
            throw ApelinError(.badRequest, "unknown build bootstrap")
        }
        return bootstrap
    }

    // MARK: projects

    public func projectTemplates() async throws -> ProjectTemplateListResponse {
        let extensions = try await service.extensionList().extensions.filter(\.problems.isEmpty)
        return ProjectTemplateListResponse(templates: extensions.flatMap { found in
            found.templates.map { template in
                ProjectTemplate(
                    id: template.id,
                    name: template.displayName,
                    kind: found.kind.rawValue,
                    summary: template.summary,
                    parameters: template.parameters.map { parameter in
                        ProjectTemplate.Parameter(
                            name: parameter.name,
                            kind: parameter.kind,
                            summary: parameter.summary,
                            defaultValue: parameter.defaultValue.flatMap(Self.templateValue),
                        )
                    },
                )
            }
        })
    }

    public func createProject(_ request: ProjectCreateToolRequest) async throws -> ProjectCreateToolResponse {
        let created = try await service.projectCreate(ProjectCreateRequest(
            templateID: request.templateID,
            name: request.name,
            values: request.values.mapValues { value in
                switch value {
                case let .string(text): .string(text)
                case let .boolean(flag): .bool(flag)
                case let .integer(number): .number(Double(number))
                }
            },
        ))
        return ProjectCreateToolResponse(projectID: created.projectID, name: created.name)
    }

    public func renameProject(_ request: ProjectRenameToolRequest) async throws -> ProjectRenameToolResponse {
        let renamed = try await service.projectRename(ProjectRenameRequest(
            projectID: request.projectID,
            displayName: request.displayName,
            onlyIfAutomatic: request.automatic,
        ))
        return ProjectRenameToolResponse(
            projectID: renamed.projectID,
            folder: request.folder,
            displayName: renamed.displayName,
            changed: renamed.changed,
        )
    }

    static func templateValue(_ value: ApelinCore.JSONValue) -> TemplateValue? {
        switch value {
        case let .string(text): .string(text)
        case let .bool(flag): .boolean(flag)
        case let .number(number) where number.rounded() == number && abs(number) < 1e15: .integer(Int(number))
        default: nil
        }
    }

    private func distributionCheck(
        bootstrap: ApelinProtocol.BuildBootstrap?,
    ) async throws -> (diagnostics: [ProjectDiagnostic], buildSystem: BuildSystemKind?) {
        let response = try await service.projectCheck(projectID: project.id, purpose: .distribution, bootstrap: bootstrap)
        return (response.diagnostics, response.buildSystem)
    }

    private static func isDistributionWarning(_ diagnostic: ProjectDiagnostic) -> Bool {
        diagnostic.code.hasPrefix("distribution.") && diagnostic.severity != .error
    }

    static func diagnostic(_ diagnostic: ProjectDiagnostic) -> BuildDiagnostic {
        let severity: BuildDiagnostic.Severity = switch diagnostic.severity {
        case .error: .error
        case .warning: .warning
        case .note: .note
        }
        return BuildDiagnostic(
            severity: severity,
            file: diagnostic.file,
            line: diagnostic.line,
            message: diagnostic.message,
        )
    }

    public func install(_ request: InstallRequest) async throws -> InstallResponse {
        let handle = try await service.installPackage(artifactID: request.artifactID, digest: request.artifactDigest)
        var result: InstallResult?
        var conflicts: [InstallConflict] = []
        let end = try await read(handle) { event in
            if event.kind == "result", let decoded = try? event.payload?.decode(InstallResult.self) {
                result = decoded
            }
            if event.kind == "conflict", let conflict = try? event.payload?.decode(InstallConflict.self) {
                conflicts.append(conflict)
            }
        }
        return InstallResponse(
            transactionID: result?.transactionID ?? handle.taskID.rawValue,
            installationID: result?.installationID,
            packageID: result?.packageID ?? "",
            version: result?.version ?? "",
            succeeded: end.state == .succeeded,
            message: end.message ?? "",
            conflicts: conflicts.isEmpty ? nil : conflicts,
        )
    }

    public func removePackage(_ request: ApelinAgent.RemovePackageRequest) async throws -> RemovePackageResponse {
        let handle = try await service.removePackage(installationID: request.installationID)
        let end = try await read(handle) { _ in }
        return RemovePackageResponse(
            transactionID: handle.taskID.rawValue,
            succeeded: end.state == .succeeded,
            message: end.message ?? "",
        )
    }

    public func respring(_: ApelinAgent.RespringRequest) async throws -> RespringResponse {
        try await service.respring()
        return RespringResponse(
            succeeded: true,
            reconnectHint: "SpringBoard restarts; this session keeps running in the session host",
        )
    }

    // MARK: apelin_package_confirm_loaded

    public func confirmLoaded(
        _ request: ApelinAgent.ConfirmLoadedRequest,
    ) async throws -> ApelinAgent.ConfirmLoadedResponse {
        // The answer is the task's, in the session host: the respring this may
        // trigger takes the app down, not this worker.
        let response = try await service.confirmLoaded(
            buildID: request.buildID,
            targetID: request.target,
            projectID: project.id,
            trigger: request.respring ? .respring : nil,
        )
        let marker = response.evidence.first { $0.kind == "log" }
        let image = response.evidence.first { $0.kind == "image" }
        let filter = response.evidence.first { $0.kind == "filter" }
        let filterMatches: Bool? = filter.flatMap { evidence in
            if evidence.passed {
                return true
            }
            return evidence.detail.hasPrefix("absent") ? false : nil
        }
        return ApelinAgent.ConfirmLoadedResponse(
            markerLogged: marker?.passed ?? false,
            imageLoaded: image?.passed ?? false,
            filterMatches: filterMatches,
            logEvidence: marker.map { [$0.detail] } ?? [],
            imageEvidence: image.flatMap { $0.passed ? [LoadedImage(path: $0.detail)] : nil } ?? [],
            notes: response.evidence.map { "\($0.kind): \($0.detail)" }.joined(separator: "\n"),
        )
    }

    // MARK: SDK

    public func registeredSDK(_ request: RegisteredSDKRequest) async throws -> RegisteredSDKResponse {
        let list = try await service.sdkList()
        let wanted = request.sdkID ?? Self.pinnedSDK(projectURL: projectURL)
        let record = wanted.flatMap { id in list.sdks.first { $0.id == id || $0.canonicalName == id } }
            ?? list.sdks.first
        guard let record else { throw ApelinError(.notFound, "no SDK is registered; add one in Apelin's SDK manager") }
        if let asked = request.sdkID, record.id != asked, record.canonicalName != asked {
            throw ApelinError(.notFound, "no registered SDK matches \(asked)")
        }
        return RegisteredSDKResponse(
            sdkID: record.id,
            rootPath: record.path,
            platform: "iphoneos",
            version: record.version,
        )
    }

    /// `environment.sdk.id` in the project's `apelin-project.json`.
    static func pinnedSDK(projectURL: URL) -> String? {
        let url = projectURL.appendingPathComponent("apelin-project.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let json = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data)
        else { return nil }
        return json.value(at: "environment.sdk.id")?.stringValue
    }

    // MARK: git

    public func gitStatus(_: GitStatusToolRequest) async throws -> GitStatusToolResponse {
        let status = try await git("git status") { try await service.gitStatus(projectID: project.id) }
        return GitStatusToolResponse(
            branch: status.branch,
            head: status.head,
            entries: status.entries.map { GitStatusToolEntry(path: $0.path, index: $0.index, worktree: $0.worktree) },
        )
    }

    public func gitDiff(_ request: GitDiffToolRequest) async throws -> GitDiffToolResponse {
        let response = try await git("git diff") {
            try await service.gitDiff(projectID: project.id, path: request.path, staged: request.staged)
        }
        let (diff, truncated) = Self.bounded(response.diff, bytes: Self.maximumDiffBytes)
        return GitDiffToolResponse(diff: diff, truncated: truncated)
    }

    public func gitStage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        try await git("git stage") { try await service.gitStage(projectID: project.id, paths: request.paths) }
        return GitPathsToolResponse(paths: request.paths)
    }

    public func gitUnstage(_ request: GitPathsToolRequest) async throws -> GitPathsToolResponse {
        try await git("git unstage") { try await service.gitUnstage(projectID: project.id, paths: request.paths) }
        return GitPathsToolResponse(paths: request.paths)
    }

    public func gitCommit(_ request: GitCommitToolRequest) async throws -> GitCommitToolResponse {
        let response = try await git("git commit") {
            try await service.gitCommit(GitCommitRequest(
                projectID: project.id,
                message: request.message,
                all: request.all ? true : nil,
            ))
        }
        return GitCommitToolResponse(commitID: response.commitID)
    }

    public func gitInit(_: GitInitToolRequest) async throws -> GitInitToolResponse {
        let response = try await git("git init") { try await service.gitInit(projectID: project.id) }
        return GitInitToolResponse(branch: response.branch)
    }

    public func gitFetch(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        try await gitTask("git fetch") { try await service.gitFetch(projectID: project.id, remote: request.remote) }
    }

    public func gitPull(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        try await gitTask("git pull") { try await service.gitPull(projectID: project.id, remote: request.remote) }
    }

    public func gitPush(_ request: GitRemoteToolRequest) async throws -> GitTaskToolResponse {
        try await gitTask("git push") {
            try await service.gitPush(GitPushRequest(
                projectID: project.id,
                remote: request.remote,
                branch: request.branch,
            ))
        }
    }

    public func gitClone(_ request: GitCloneToolRequest) async throws -> GitTaskToolResponse {
        let host = URLComponents(string: request.url)?.host
        return try await gitTask("git clone", host: host) {
            try await service.gitCloneInto(GitCloneIntoRequest(
                projectID: project.id,
                url: request.url,
                branch: request.branch,
            ))
        }
    }

    public func gitSettings(context _: HostCallContext) async throws -> GitSettingsToolResponse {
        try await Self.settings(git("git settings") { try await service.gitSettings() })
    }

    public func gitSetAuthor(_ request: GitAuthorToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git set author") { try await service.gitAuthorSet(name: request.name, email: request.email) }
        return try await gitSettings(context: request.context)
    }

    public func gitSaveCredential(_ request: GitCredentialToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git save credential") {
            try await service.gitCredentialSet(GitCredentialSetRequest(
                host: request.host,
                username: request.username,
                token: request.token,
            ))
        }
        return try await gitSettings(context: request.context)
    }

    public func gitRemoveCredential(_ request: GitCredentialRemoveToolRequest) async throws -> GitSettingsToolResponse {
        try await git("git remove credential") { try await service.gitCredentialRemove(host: request.host) }
        return try await gitSettings(context: request.context)
    }

    static func settings(_ response: GitSettingsResponse) -> GitSettingsToolResponse {
        GitSettingsToolResponse(
            authorName: response.authorName,
            authorEmail: response.authorEmail,
            credentials: response.credentials.map { .init(host: $0.host, username: $0.username) },
        )
    }

    /// One git request; a refusal comes back as a `GitToolFailure` that says
    /// what to do about it.
    private func git<T>(_ operation: String, host: String? = nil, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ApelinError {
            throw GitFailure.describe(
                operation,
                code: error.code,
                message: error.message,
                reason: error.reason?.rawValue,
                host: host,
            )
        }
    }

    /// Starts a git task and reads it to its final `state`: the `result` it
    /// reported, or a failure in words.
    private func gitTask(
        _ operation: String,
        host: String? = nil,
        _ start: () async throws -> TaskHandle,
    ) async throws -> GitTaskToolResponse {
        let handle = try await git(operation, host: host, start)
        var result: ApelinCore.JSONValue?
        var reason: String?
        let end = try await read(handle) { event in
            if event.kind == "result" {
                result = event.payload
            } else if event.kind == TaskEvent.stateKind {
                result = event.payload?["result"] ?? result
                reason = event.payload?["reason"]?.stringValue
            }
        }
        switch end.state {
        case .succeeded:
            return Self.gitResult(result)
        case .cancelled:
            throw GitToolFailure(message: "\(operation) was cancelled.")
        case .interrupted:
            throw GitToolFailure(message: "\(operation) was cut off when the session host stopped; check git_status, then run it again if it is still needed.")
        default:
            let (code, message) = GitFailure.split(end.message)
            throw GitFailure.describe(operation, code: code, message: message, reason: reason, host: host)
        }
    }

    static func gitResult(_ json: ApelinCore.JSONValue?) -> GitTaskToolResponse {
        guard let json else { return GitTaskToolResponse() }
        var updates: [GitRefUpdate]?
        if case let .array(entries)? = json["updated"] {
            updates = entries.compactMap { entry in
                guard let ref = entry["ref"]?.stringValue, let to = entry["to"]?.stringValue else { return nil }
                return GitRefUpdate(ref: ref, from: entry["from"]?.stringValue, to: to)
            }
        }
        var upToDate: Bool?
        if case let .bool(flag)? = json["upToDate"] {
            upToDate = flag
        }
        return GitTaskToolResponse(
            remote: json["remote"]?.stringValue,
            branch: json["branch"]?.stringValue,
            commit: json["commit"]?.stringValue,
            from: json["from"]?.stringValue,
            to: json["to"]?.stringValue,
            upToDate: upToDate,
            updated: updates,
        )
    }

    /// At most `bytes` of `text`, cut at a line end where one is near.
    static func bounded(_ text: String, bytes: Int) -> (String, Bool) {
        let utf8 = text.utf8
        guard utf8.count > bytes else { return (text, false) }
        var cut = utf8.index(utf8.startIndex, offsetBy: bytes)
        while cut > utf8.startIndex, String.Index(cut, within: text) == nil {
            cut = utf8.index(before: cut)
        }
        let head = text[..<cut]
        let lines = head.lastIndex(of: "\n").map { head[...$0] } ?? head
        return (String(lines) + "\n… (diff cut at \(bytes / 1024) KiB; pass a path to see one file)\n", true)
    }

    // MARK: Helpers

    struct TaskEnd {
        var state: TaskState
        var message: String?
    }

    /// Reads a task to its end, handing each event to `body`.
    func read(_ handle: TaskHandle, _ body: (TaskEvent) throws -> Void) async throws -> TaskEnd {
        var end = TaskEnd(state: .running, message: nil)
        for try await event in service.events(of: handle) {
            if event.kind == TaskEvent.stateKind, let name = event.payload?["state"]?.stringValue, let state = TaskState(rawValue: name) {
                end = TaskEnd(state: state, message: event.payload?["message"]?.stringValue)
            }
            try body(event)
        }
        return end
    }

    /// Up to `limit` bytes from the descriptor's current offset.
    static func read(_ descriptor: Int32, upTo limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if count < 0, errno == EINTR {
                continue
            }
            if count < 0 {
                throw ApelinError(.internal, "read: \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }
}
