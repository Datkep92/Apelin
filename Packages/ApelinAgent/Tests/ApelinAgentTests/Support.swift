@testable import ApelinAgent
import Foundation

/// A throwaway home with `Documents/wiki.qaq.apelin/Projects/<name>/`.
struct TemporaryHome {
    let home: URL
    let dataRoot: ApelinDataRoot
    let project: ProjectIdentity
    let projectURL: URL

    init(projectName: String = "Hello") throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-agent-tests-\(UUID().uuidString)", isDirectory: true)
        dataRoot = ApelinDataRoot(home: home)
        project = try ProjectIdentity(id: "project-\(UUID().uuidString.prefix(8))", name: ProjectName(projectName))
        projectURL = dataRoot.project(named: project.name)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    func write(_ relative: String, _ content: String) throws {
        let url = projectURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: projectURL.appendingPathComponent(relative), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// The host's side of the digest rule: what the template says, what was
/// approved, and the recording the host does when it relays an approval.
actor MockDigestLedger: ApprovalDigestStore {
    var current: [DescriptionKind: String] = [.build: "build-template", .packaging: "packaging-template"]
    var template: [DescriptionKind: String] = [.build: "build-template", .packaging: "packaging-template"]
    var approved: Set<String> = []

    func state(of kind: DescriptionKind, for project: ProjectIdentity) -> DescriptionState {
        let digest = current[kind]!
        if digest == template[kind] {
            return DescriptionState(digest: digest, baseline: .matchesTemplate)
        }
        if approved.contains("\(project.id)/\(kind.rawValue)/\(digest)") {
            return DescriptionState(digest: digest, baseline: .approved)
        }
        return DescriptionState(digest: digest, baseline: .changed(diff: "- \(template[kind]!)\n+ \(digest)"))
    }

    func change(_ kind: DescriptionKind, to digest: String) {
        current[kind] = digest
    }

    /// What the host does when it relays a user's approval of a
    /// `.descriptionChanged` request.
    func record(_ request: ApprovalRequest, decision: ApprovalDecision) {
        guard case .approve = decision, case let .descriptionChanged(kind, digest, _) = request.detail else { return }
        approved.insert("\(request.projectID)/\(kind.rawValue)/\(digest)")
    }
}

/// Records every call and answers with fixed values.
actor MockBackend: AgentHostBackend {
    enum Call: Equatable {
        case runCode(RunCodeInvocation)
        case build(digest: String, evidence: ApprovalEvidence)
        case install(artifact: String, digest: String, packaging: String, evidence: ApprovalEvidence)
        case removePackage(String)
        case respring
        case confirmLoaded(build: String, target: String)
        case createProject(template: String, name: String, values: [String: TemplateValue])
        case gitStatus
        case gitDiff(path: String?, staged: Bool)
        case gitStage([String])
        case gitUnstage([String])
        case gitCommit(String)
        case gitFetch(remote: String?)
        case gitPull(remote: String?)
        case gitPush(remote: String?, branch: String?, evidence: ApprovalEvidence)
        case gitClone(url: String, branch: String?)
        case gitSetAuthor(name: String?, email: String?)
        case gitSaveCredential(host: String, username: String, token: String)
        case gitRemoveCredential(host: String)
        case conversationCreate(prompt: String, title: String?)
        case conversationSend(sessionID: String, text: String)
        case conversationList
        case conversationRead(sessionID: String, afterSeq: UInt64?, waitSeconds: Int)
        case conversationStop(sessionID: String, close: Bool)
        case other(String)
    }

    /// What git_status answers as the checked-out branch.
    var gitBranch: String? = "main"

    func setGitBranch(_ branch: String?) {
        gitBranch = branch
    }

    var calls: [Call] = []
    var sdkRoot: String = "/nonexistent"

    func setSDKRoot(_ path: String) {
        sdkRoot = path
    }

    /// The evidence of every run_code call, refused ones included.
    var runCodeEvidence: [ApprovalEvidence] = []
    /// Whether this host's preset rule refuses every preset, as the real
    /// host does for a call its own rule does not count.
    var refusesPresets = false

    func setRefusesPresets(_ refuses: Bool) {
        refusesPresets = refuses
    }

    func runCode(_ request: RunCodeRequest) throws -> RunCodeResponse {
        runCodeEvidence.append(request.context.approval)
        if refusesPresets, case .preset = request.context.approval {
            throw HostRefusedPresetError(message: "the host does not recognise this command as a preset; ask the user")
        }
        calls.append(.runCode(request.invocation))
        return RunCodeResponse(exitCode: 0, stdout: "ok", stderr: "")
    }

    func build(_ request: BuildRequest) -> BuildResponse {
        calls.append(.build(digest: request.buildDescriptionDigest, evidence: request.context.approval))
        return BuildResponse(
            buildID: "build-1",
            succeeded: true,
            artifacts: [BuildArtifact(id: "artifact-1", kind: .package, name: "hello.deb", digest: "deb-digest-1")],
        )
    }

    func install(_ request: InstallRequest) -> InstallResponse {
        calls.append(.install(artifact: request.artifactID, digest: request.artifactDigest, packaging: request.packagingDescriptionDigest, evidence: request.context.approval))
        return InstallResponse(transactionID: "tx-1", installationID: "inst-1", packageID: "wiki.qaq.hello", version: "1.0", succeeded: true)
    }

    func removePackage(_ request: RemovePackageRequest) -> RemovePackageResponse {
        calls.append(.removePackage(request.installationID))
        return RemovePackageResponse(transactionID: "tx-2", succeeded: true)
    }

    func respring(_: RespringRequest) -> RespringResponse {
        calls.append(.respring)
        return RespringResponse(succeeded: true)
    }

    func confirmLoaded(_ request: ConfirmLoadedRequest) -> ConfirmLoadedResponse {
        calls.append(.confirmLoaded(build: request.buildID, target: request.target))
        return ConfirmLoadedResponse(markerLogged: true, imageLoaded: true, filterMatches: true, logEvidence: ["Hello loaded build-1"])
    }

    func readLogs(_: ReadLogsRequest) -> ReadLogsResponse {
        calls.append(.other("readLogs"))
        return ReadLogsResponse(entries: [])
    }

    func listCrashes(_: ListCrashesRequest) -> ListCrashesResponse {
        calls.append(.other("listCrashes"))
        return ListCrashesResponse(reports: [])
    }

    func readCrash(_ request: ReadCrashRequest) -> ReadCrashResponse {
        calls.append(.other("readCrash"))
        return ReadCrashResponse(reportID: request.reportID, text: "")
    }

    func symbolicateCrash(_ request: SymbolicateCrashRequest) -> SymbolicateCrashResponse {
        calls.append(.other("symbolicateCrash"))
        return SymbolicateCrashResponse(reportID: request.reportID, matchedImageUUID: nil, crashedThread: [])
    }

    func captureScreen(_: CaptureScreenRequest) -> CaptureScreenResponse {
        calls.append(.other("captureScreen"))
        return CaptureScreenResponse(attachmentID: "att-1", mimeType: "image/png", width: 1, height: 1, imageData: Data([0x89, 0x50]))
    }

    func readUITree(_: ReadUITreeRequest) -> ReadUITreeResponse {
        calls.append(.other("readUITree"))
        return ReadUITreeResponse(root: UIElementNode(id: "root", role: "application"))
    }

    func uiAction(_: UIActionRequest) -> UIActionResponse {
        calls.append(.other("uiAction"))
        return UIActionResponse(performed: true)
    }

    func registeredSDK(_: RegisteredSDKRequest) -> RegisteredSDKResponse {
        RegisteredSDKResponse(sdkID: "iPhoneOS16.5", rootPath: sdkRoot, platform: "iphoneos", version: "16.5")
    }

    func checkDistribution(_: DistributionCheckRequest) -> DistributionCheckResponse {
        DistributionCheckResponse(ready: true)
    }

    func projectTemplates() -> ProjectTemplateListResponse {
        ProjectTemplateListResponse(templates: [
            ProjectTemplate(id: "wiki.qaq.apelin.dev.tweak/tweak", name: "Tweak", kind: "tweak", parameters: [
                ProjectTemplate.Parameter(name: "filter", kind: "string", defaultValue: .string("com.apple.springboard")),
            ]),
        ])
    }

    func createProject(_ request: ProjectCreateToolRequest) -> ProjectCreateToolResponse {
        calls.append(.createProject(template: request.templateID, name: request.name, values: request.values))
        return ProjectCreateToolResponse(projectID: "project-1", name: request.name)
    }

    func gitStatus(_: GitStatusToolRequest) -> GitStatusToolResponse {
        calls.append(.gitStatus)
        return GitStatusToolResponse(branch: gitBranch, head: "abc123", entries: [])
    }

    func gitDiff(_ request: GitDiffToolRequest) -> GitDiffToolResponse {
        calls.append(.gitDiff(path: request.path, staged: request.staged))
        return GitDiffToolResponse(diff: "")
    }

    func gitStage(_ request: GitPathsToolRequest) -> GitPathsToolResponse {
        calls.append(.gitStage(request.paths))
        return GitPathsToolResponse(paths: request.paths)
    }

    func gitUnstage(_ request: GitPathsToolRequest) -> GitPathsToolResponse {
        calls.append(.gitUnstage(request.paths))
        return GitPathsToolResponse(paths: request.paths)
    }

    func gitCommit(_ request: GitCommitToolRequest) -> GitCommitToolResponse {
        calls.append(.gitCommit(request.message))
        return GitCommitToolResponse(commitID: "def456")
    }

    func gitFetch(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        calls.append(.gitFetch(remote: request.remote))
        return GitTaskToolResponse(remote: request.remote ?? "origin", updated: [])
    }

    func gitPull(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        calls.append(.gitPull(remote: request.remote))
        return GitTaskToolResponse(branch: gitBranch, upToDate: true)
    }

    func gitPush(_ request: GitRemoteToolRequest) -> GitTaskToolResponse {
        calls.append(.gitPush(remote: request.remote, branch: request.branch, evidence: request.context.approval))
        return GitTaskToolResponse(remote: request.remote ?? "origin", branch: request.branch, commit: "abc123")
    }

    func gitClone(_ request: GitCloneToolRequest) -> GitTaskToolResponse {
        calls.append(.gitClone(url: request.url, branch: request.branch))
        return GitTaskToolResponse(branch: request.branch ?? "main", commit: "abc123")
    }

    func gitSettings(context _: HostCallContext) -> GitSettingsToolResponse {
        calls.append(.other("gitSettings"))
        return GitSettingsToolResponse(credentials: [.init(host: "github.com", username: "octocat")])
    }

    func gitSetAuthor(_ request: GitAuthorToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitSetAuthor(name: request.name, email: request.email))
        return GitSettingsToolResponse(authorName: request.name, authorEmail: request.email)
    }

    func gitSaveCredential(_ request: GitCredentialToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitSaveCredential(host: request.host, username: request.username, token: request.token))
        return GitSettingsToolResponse(credentials: [.init(host: request.host, username: request.username)])
    }

    func gitRemoveCredential(_ request: GitCredentialRemoveToolRequest) -> GitSettingsToolResponse {
        calls.append(.gitRemoveCredential(host: request.host))
        return GitSettingsToolResponse()
    }

    func conversationCreate(_ request: ConversationCreateToolRequest) -> ConversationCreateToolResponse {
        calls.append(.conversationCreate(prompt: request.prompt, title: request.title))
        return ConversationCreateToolResponse(sessionID: "child-session", taskID: "child-task")
    }

    func conversationSend(_ request: ConversationSendToolRequest) -> ConversationActionToolResponse {
        calls.append(.conversationSend(sessionID: request.sessionID, text: request.text))
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "sent")
    }

    func conversationList(context _: HostCallContext) -> ConversationListToolResponse {
        calls.append(.conversationList)
        return ConversationListToolResponse(conversations: [])
    }

    func conversationRead(_ request: ConversationReadToolRequest) -> ConversationReadToolResponse {
        calls.append(.conversationRead(sessionID: request.sessionID, afterSeq: request.afterSeq, waitSeconds: request.waitSeconds))
        return ConversationReadToolResponse(sessionID: request.sessionID, state: .idle, lastSeq: 0)
    }

    func conversationStop(_ request: ConversationStopToolRequest) -> ConversationActionToolResponse {
        calls.append(.conversationStop(sessionID: request.sessionID, close: request.close))
        return ConversationActionToolResponse(sessionID: request.sessionID, done: request.close ? "closed" : "stopped")
    }
}

/// Collects session events in order.
actor EventCollector {
    var events: [AgentSessionEvent] = []
    func add(_ event: AgentSessionEvent) {
        events.append(event)
    }
}
