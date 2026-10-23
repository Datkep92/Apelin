import struct ApelinCore.MemoryStore
import enum ApelinCore.MemoryStoreError
import enum ApelinProtocol.BuildBootstrap
import Foundation
import KWWKAgent
import KWWKAI

public struct ToolDeniedError: Error, LocalizedError {
    public var message: String
    public var errorDescription: String? {
        message
    }
}

/// Gathers the facts of a call, puts it through the approval gate, then runs
/// it: file tools here, everything else through the host backend.
actor ToolRunner {
    let sessionID: String
    let project: ProjectIdentity
    let root: ScopedRoot
    private var policy: ApprovalPolicy
    let backend: any AgentHostBackend
    let digests: any ApprovalDigestStore
    let gate: ApprovalGate
    let memory: MemoryStore?
    let skills: URL?

    init(
        sessionID: String,
        project: ProjectIdentity,
        root: ScopedRoot,
        policy: ApprovalPolicy,
        backend: any AgentHostBackend,
        digests: any ApprovalDigestStore,
        gate: ApprovalGate,
        memory: MemoryStore? = nil,
        skills: URL? = nil,
    ) {
        self.sessionID = sessionID
        self.project = project
        self.root = root
        self.policy = policy
        self.backend = backend
        self.digests = digests
        self.gate = gate
        self.memory = memory
        self.skills = skills
    }

    @discardableResult
    func setMode(_ mode: ApprovalMode) -> Bool {
        guard policy.mode != mode else { return false }
        policy.mode = mode
        return true
    }

    var approvalMode: ApprovalMode {
        policy.mode
    }

    static let maxImageBytes = 4 * 1024 * 1024

    /// kwwk tool definitions for the §7 tools plus wrapped MCP tools.
    nonisolated func agentTools(mcp: [AgentTool]) -> [AgentTool] {
        let offered = AgentToolName.allCases.filter { project.isTemporary ? !$0.isProjectOnly : !$0.isGeneralChatOnly }
        var tools = offered.map { name in
            AgentTool(
                name: name.rawValue,
                label: name.rawValue,
                description: name.summary,
                parameters: ToolReason.adding(to: name.parameters),
            ) { id, args, cancellation, _ in
                try await self.run(
                    .local(name),
                    toolCallID: id,
                    arguments: ToolReason.removing(from: args),
                    cancellation: cancellation,
                    mcp: nil,
                )
            }
        }
        for tool in mcp {
            var wrapped = tool
            let inner = tool.execute
            let name = tool.name
            wrapped.parameters = ToolReason.adding(to: tool.parameters)
            wrapped.execute = { id, args, cancellation, update in
                try await self.run(
                    .mcp(name),
                    toolCallID: id,
                    arguments: ToolReason.removing(from: args),
                    cancellation: cancellation,
                ) { args in
                    try await inner(id, args, cancellation, update)
                }
            }
            tools.append(wrapped)
        }
        return tools
    }

    // MARK: - Gate

    func run(
        _ tool: InvocationFacts.Tool,
        toolCallID: String,
        arguments: JSONValue,
        cancellation: CancellationHandle?,
        mcp: (@Sendable (JSONValue) async throws -> AgentToolResult)?,
    ) async throws -> AgentToolResult {
        let arguments = switch tool {
        case let .local(name): ToolArguments.normalized(arguments, for: name)
        case .mcp: arguments
        }
        // Before the gate: a workspace has no build description to approve.
        if case .local(.build) = tool, ProjectBuildSystem.read(in: root) == .external {
            throw ToolDeniedError(message: ProjectBuildSystem.externalBuildRefusal)
        }
        let facts = try await gatherFacts(tool, arguments: arguments)
        let workingDirectory = arguments.argString("cwd") ?? "."
        let toolName: String = switch tool {
        case let .local(name): name.rawValue
        case let .mcp(name): name
        }
        let fingerprint = ApprovalFingerprint.make(
            tool: toolName,
            arguments: arguments,
            workingDirectory: workingDirectory,
            projectID: project.id,
            digest: facts.description?.digest,
        )

        let ask = { (reason: String, detail: ApprovalDetail) async throws -> ApprovalEvidence in
            try await self.askUser(
                tool,
                toolName: toolName,
                toolCallID: toolCallID,
                arguments: arguments,
                workingDirectory: workingDirectory,
                fingerprint: fingerprint,
                reason: reason,
                detail: detail,
                cancellation: cancellation,
            )
        }
        let hostRefusal = "Apelin could not confirm that this command is one of your approved presets. Review it before running."
        let evidence: ApprovalEvidence
        switch policy.evaluate(facts, root: root) {
        case let .allow(allowed):
            evidence = allowed
        case let .deny(reason):
            throw ToolDeniedError(message: "refused: \(reason)")
        case let .ask(reason, detail):
            evidence = try await ask(reason, detail)
        }
        try cancellation?.throwIfCancelled()

        if let mcp {
            return try await mcp(arguments)
        }
        guard case let .local(name) = tool else { throw ToolDeniedError(message: "unknown tool") }
        var context = HostCallContext(
            sessionID: sessionID,
            project: project,
            toolCallID: toolCallID,
            approval: evidence,
        )
        do {
            return try await execute(
                name,
                arguments: arguments,
                facts: facts,
                context: context,
                cancellation: cancellation,
            )
        } catch let refusal as HostRefusedPresetError {
            // The host's preset rule is the one that counts: where it does
            // not count this call, the user decides, as for any command no
            // preset covers, and the call goes again with that approval.
            // Nothing is remembered: the host's answer depends on the
            // repository (a `.git` made, a `.gitmodules` removed), so the
            // next call is sent as a preset again and the host decides.
            guard case .preset = evidence, let command = facts.command else { throw refusal }
            context.approval = try await ask(hostRefusal, .command(command))
            try cancellation?.throwIfCancelled()
            return try await execute(
                name,
                arguments: arguments,
                facts: facts,
                context: context,
                cancellation: cancellation,
            )
        }
    }

    /// Asks the user about one call — unless it is one they approved for
    /// this session — and answers the evidence to send, or throws when they
    /// decline.
    private func askUser(
        _ tool: InvocationFacts.Tool,
        toolName: String,
        toolCallID: String,
        arguments: JSONValue,
        workingDirectory: String,
        fingerprint: String,
        reason: String,
        detail: ApprovalDetail,
        cancellation: CancellationHandle?,
    ) async throws -> ApprovalEvidence {
        let sessionScope = Self.allowsSessionScope(tool, detail: detail)
        if sessionScope, await gate.isRemembered(fingerprint) {
            return .user(requestID: ApprovalEvidence.sessionRequestID, fingerprint: fingerprint)
        }
        let request = ApprovalRequest(
            id: UUID().uuidString,
            toolCallID: toolCallID,
            tool: toolName,
            arguments: arguments.canonicalJSON,
            workingDirectory: workingDirectory,
            projectID: project.id,
            fingerprint: fingerprint,
            reason: reason,
            detail: detail,
            allowsSessionScope: sessionScope,
        )
        switch await gate.request(request, cancellation: cancellation) {
        case .approve:
            return .user(requestID: request.id, fingerprint: fingerprint)
        case let .deny(reason):
            throw ToolDeniedError(message: "the user declined this call\(reason.map { ": \($0)" } ?? "")")
        }
    }

    /// "For this session" is never offered for package removal or for a
    /// request bound to a description digest: the host's ledger keeps those.
    /// Nor for a push: each one publishes, so each one is asked. Nor for a
    /// toolchain or SDK install, which changes the device for every
    /// project, nor for a call that reaches another project.
    static func allowsSessionScope(_ tool: InvocationFacts.Tool, detail: ApprovalDetail) -> Bool {
        switch tool {
        case .local(.removePackage), .local(.gitPush), .local(.toolchainSetup), .local(.sdkImport):
            return false
        default:
            break
        }
        switch detail {
        case .gitSettings, .descriptionChanged, .toolchainSetup, .sdkImport, .otherProject:
            return false
        case .none, .command, .packageRemoval, .gitPush:
            return true
        }
    }

    // MARK: - Execution

    private func execute(
        _ name: AgentToolName,
        arguments: JSONValue,
        facts: InvocationFacts,
        context: HostCallContext,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let files = ProjectFileTools(root: root)
        switch name {
        case .memoryList, .memorySave, .memoryDelete:
            guard let memory else { throw ToolDeniedError(message: "Memory storage is unavailable.") }
            let tools = MemoryTools(store: memory, projectID: project.id)
            do {
                switch name {
                case .memoryList: return try json(tools.list())
                case .memorySave: return try json(tools.save(arguments))
                default: return try json(tools.delete(arguments))
                }
            } catch MemoryStoreError.changed {
                throw ToolDeniedError(message: "Memory changed. Read memory_list again and respect the user's latest corrections or deletions; do not blindly retry.")
            } catch MemoryStoreError.invalidContent {
                throw ToolArgumentError("Memory needs a valid title (1–\(MemoryStore.maximumTitleLength) characters) and body (1–\(MemoryStore.maximumBodyLength) characters), without NUL bytes.")
            } catch MemoryStoreError.full {
                throw ToolArgumentError("Memory is full (\(MemoryStore.maximumRecords) records or \(MemoryStore.maximumContentBytes) content bytes). Consolidate outdated records before adding more.")
            }

        case .readSkill:
            guard let skills else { throw ToolDeniedError(message: "Skills are unavailable.") }
            return try text(SkillReader(userDirectory: skills).read(arguments))

        case .writeFile: return try text(files.writeFile(arguments))

        case .patchFile: return try text(files.patchFile(arguments))

        case .createFile: return try text(files.createFile(arguments))

        case .readFile: return try text(files.readFile(arguments))

        case .list: return try text(files.list(arguments))

        case .grep: return try text(files.grep(arguments))

        case .find: return try text(files.find(arguments))

        case .checkDistribution:
            let bootstrap = try Self.bootstrap(arguments)
            return try await json(backend.checkDistribution(DistributionCheckRequest(
                project: project,
                bootstrap: bootstrap,
            )))

        case .projectTemplateList:
            return try await json(backend.projectTemplates())

        case .projectCreate:
            guard project.isTemporary else { throw ToolDeniedError(message: "only General Chat creates projects") }
            return try await json(backend.createProject(ProjectCreateToolRequest(
                context: context,
                templateID: arguments.requireString("template"),
                name: arguments.requireString("name"),
                values: Self.templateValues(arguments),
            )))

        case .analyzeFramework, .frameworkHeader:
            let sdk = try await backend.registeredSDK(RegisteredSDKRequest(
                sdkID: arguments.argString("sdk_id"),
                project: project,
            ))
            let tools = try FrameworkTools(sdk: ScopedRoot(URL(fileURLWithPath: sdk.rootPath, isDirectory: true)))
            let output = name == .analyzeFramework ? try tools.analyze(arguments) : try tools.header(arguments)
            return text("SDK \(sdk.sdkID) (\(sdk.platform) \(sdk.version))\n\(output)")

        case .runCode:
            guard let invocation = facts.command else {
                throw ToolArgumentError("run_code needs argv, command or script")
            }
            let timeout = min(1800, max(1, arguments.argInt("timeout_seconds") ?? 120))
            return try await json(backend.runCode(RunCodeRequest(
                context: context,
                invocation: invocation,
                workingDirectory: facts.workingDirectory,
                timeoutSeconds: timeout,
            )))

        case .build:
            guard let state = facts.description else {
                throw ToolDeniedError(message: "the build description could not be checked")
            }
            let configuration = BuildConfiguration(rawValue: arguments.argString("configuration") ?? "debug") ?? .debug
            return try await json(backend.build(BuildRequest(
                context: context,
                configuration: configuration,
                buildDescriptionDigest: state.digest,
                bootstrap: Self.bootstrap(arguments),
            )))

        case .install:
            guard let state = facts.description else {
                throw ToolDeniedError(message: "the packaging description could not be checked")
            }
            return try await json(backend.install(InstallRequest(
                context: context,
                artifactID: arguments.requireString("artifact_id"),
                artifactDigest: arguments.requireString("artifact_digest"),
                packagingDescriptionDigest: state.digest,
            )))

        case .removePackage:
            return try await json(backend.removePackage(RemovePackageRequest(
                context: context,
                installationID: arguments.requireString("installation_id"),
            )))

        case .respring:
            return try await json(backend.respring(RespringRequest(context: context)))

        case .confirmLoaded:
            return try await json(backend.confirmLoaded(ConfirmLoadedRequest(
                context: context,
                buildID: arguments.requireString("build_id"),
                target: arguments.requireString("target"),
                respring: arguments.argBool("respring") ?? false,
            )))

        case .readLogs:
            return try await json(backend.readLogs(ReadLogsRequest(
                context: context,
                process: arguments.argString("process"),
                subsystem: arguments.argString("subsystem"),
                sinceSeconds: min(3600, max(1, arguments.argInt("since_seconds") ?? 300)),
                limit: min(1000, max(1, arguments.argInt("limit") ?? 200)),
            )))

        case .listCrashes:
            return try await json(backend.listCrashes(ListCrashesRequest(
                context: context,
                process: arguments.argString("process"),
                limit: min(200, max(1, arguments.argInt("limit") ?? 20)),
            )))

        case .readCrash:
            return try await json(backend.readCrash(ReadCrashRequest(
                context: context,
                reportID: arguments.requireString("report_id"),
                maxBytes: 256 * 1024,
            )))

        case .symbolicateCrash:
            return try await json(backend.symbolicateCrash(SymbolicateCrashRequest(
                context: context,
                reportID: arguments.requireString("report_id"),
                buildID: arguments.argString("build_id"),
            )))

        case .captureScreen:
            var response = try await backend.captureScreen(CaptureScreenRequest(
                context: context,
                targetID: arguments.argString("target_id"),
            ))
            let image = response.imageData.flatMap { $0.count <= Self.maxImageBytes ? $0 : nil }
            response.imageData = nil
            var result = json(response)
            if let image {
                result.content.append(.image(ImageContent(
                    data: image.base64EncodedString(),
                    mimeType: response.mimeType,
                )))
            }
            return result

        case .readUITree:
            return try await json(backend.readUITree(ReadUITreeRequest(
                context: context,
                targetID: arguments.argString("target_id"),
                maxDepth: min(40, max(1, arguments.argInt("max_depth") ?? 12)),
            )))

        case .uiAction:
            return try await json(backend.uiAction(UIActionRequest(
                context: context,
                targetID: arguments.argString("target_id"),
                action: Self.uiAction(arguments),
            )))

        case .gitStatus:
            return try await json(backend.gitStatus(GitStatusToolRequest(context: context)))

        case .gitDiff:
            return try await json(backend.gitDiff(GitDiffToolRequest(
                context: context,
                path: arguments.argNonEmptyString("path"),
                staged: arguments.argBool("staged") ?? false,
            )))

        case .gitStage, .gitUnstage:
            guard let paths = arguments.argStrings("paths"), !paths.isEmpty else {
                throw ToolArgumentError("paths must be a non-empty list of project-relative paths")
            }
            let request = GitPathsToolRequest(context: context, paths: paths)
            return try await json(name == .gitStage ? backend.gitStage(request) : backend.gitUnstage(request))

        case .gitCommit:
            let message = try arguments.requireString("message")
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the commit message is empty")
            }
            return try await json(backend.gitCommit(GitCommitToolRequest(context: context, message: message)))

        case .gitFetch, .gitPull:
            // No remote named is the host's default, `origin`.
            let request = GitRemoteToolRequest(context: context, remote: arguments.argNonEmptyString("remote"))
            return try await json(name == .gitFetch ? backend.gitFetch(request) : backend.gitPull(request))

        case .gitPush:
            return try await json(backend.gitPush(GitRemoteToolRequest(
                context: context,
                remote: arguments.argNonEmptyString("remote"),
                branch: facts.push?.branch,
            )))

        case .gitClone:
            return try await json(backend.gitClone(GitCloneToolRequest(
                context: context,
                url: arguments.requireString("url"),
                branch: arguments.argNonEmptyString("branch"),
            )))

        case .gitSettings:
            return try await json(backend.gitSettings(context: context))

        case .gitSetAuthor:
            return try await json(backend.gitSetAuthor(GitAuthorToolRequest(
                context: context,
                name: arguments.argString("name"),
                email: arguments.argString("email"),
            )))

        case .gitSaveCredential:
            return try await json(backend.gitSaveCredential(GitCredentialToolRequest(
                context: context,
                host: arguments.requireString("host"),
                username: arguments.requireString("username"),
                token: arguments.requireString("token"),
            )))

        case .gitRemoveCredential:
            return try await json(backend.gitRemoveCredential(GitCredentialRemoveToolRequest(
                context: context,
                host: arguments.requireString("host"),
            )))

        case .conversationCreate:
            let prompt = try arguments.requireString("prompt")
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the prompt is empty: say what the other conversation should do and deliver")
            }
            return try await json(backend.conversationCreate(ConversationCreateToolRequest(
                context: context,
                prompt: prompt,
                title: arguments.argNonEmptyString("title"),
                target: facts.targetProject,
            )))

        case .conversationSend:
            let target = try Self.conversation(arguments)
            guard target != sessionID else {
                throw ToolArgumentError("session_id is this conversation; send to another one")
            }
            let text = try arguments.requireString("text")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolArgumentError("the message is empty")
            }
            return try await json(backend.conversationSend(ConversationSendToolRequest(
                context: context,
                sessionID: target,
                text: text,
                target: facts.targetProject,
            )))

        case .conversationList:
            return try await json(backend.conversationList(ConversationListToolRequest(
                context: context,
                target: facts.targetProject,
            )))

        case .conversationRead:
            let request = try ConversationReadToolRequest(
                context: context,
                sessionID: Self.conversation(arguments),
                afterSeq: arguments.argInt("after_seq").map { UInt64(max(0, $0)) },
                waitSeconds: Self.conversationWait(arguments),
                target: facts.targetProject,
            )
            let backend = backend
            return try await json(Self.untilCancelled(cancellation) { try await backend.conversationRead(request) })

        case .conversationStop:
            return try await json(backend.conversationStop(ConversationStopToolRequest(
                context: context,
                sessionID: Self.conversation(arguments),
                close: arguments.argBool("close") ?? false,
            )))

        case .toolchainList:
            return try await json(backend.toolchains(context: context))

        case .sdkList:
            return try await json(backend.sdks(context: context))

        case .toolchainSetup:
            // The release the card named, by product ID.
            guard let setup = facts.toolchainSetup else {
                throw ToolDeniedError(message: "the toolchain to set up could not be identified")
            }
            return try await json(backend.toolchainSetup(ToolchainSetupToolRequest(
                context: context,
                productID: setup.productID,
                components: setup.components,
            )))

        case .sdkImport:
            guard let sdkImport = facts.sdkImport else {
                throw ToolDeniedError(message: "the SDK to import could not be identified")
            }
            return try await json(backend.sdkImport(SDKImportToolRequest(
                context: context,
                url: sdkImport.url,
                branch: sdkImport.branch,
            )))

        case .toolchainSelfTest:
            return try await json(backend.toolchainSelfTest(ToolchainSelfTestToolRequest(
                context: context,
                toolchainID: arguments.requireString("toolchain_id"),
            )))

        case .projectEnvironmentSet:
            return try await json(setEnvironment(arguments, context: context))
        }
    }

    /// Switches the project's toolchain and/or SDK: checked by the host as
    /// a project bound to them would be, refused on any `environment.*`
    /// error with its reason, then written into apelin-project.json through
    /// the file tools' writer with the registry's digests.
    private func setEnvironment(
        _ arguments: JSONValue,
        context: HostCallContext,
    ) async throws -> ProjectEnvironmentSetToolResponse {
        let toolchainID = arguments.argNonEmptyString("toolchain_id")
        let sdkID = arguments.argNonEmptyString("sdk_id")
        guard toolchainID != nil || sdkID != nil else {
            throw ToolArgumentError("name toolchain_id, sdk_id or both")
        }
        guard ProjectBuildSystem.read(in: root) != .external else {
            throw ToolDeniedError(message: "this workspace builds with its own tools through run_code; it binds no Apelin toolchain or SDK")
        }
        let checked = try await backend.checkEnvironment(EnvironmentCheckToolRequest(
            context: context,
            toolchainID: toolchainID,
            sdkID: sdkID,
        ))
        let errors = checked.diagnostics.filter { $0.severity == "error" }
        guard errors.isEmpty else {
            throw ToolDeniedError(message: "refused: " + errors.map(\.message).joined(separator: "; "))
        }
        let target = try root.resolveForWrite(ProjectEnvironmentEdit.fileName)
        guard target.exists else { throw PathPolicyError.notFound(ProjectEnvironmentEdit.fileName) }
        let original = try Data(contentsOf: URL(fileURLWithPath: target.finalPath))
        let edit = try ProjectEnvironmentEdit.rebind(original, toolchain: checked.toolchain, sdk: checked.sdk)
        if edit.data != original {
            try target.commit(edit.data, exclusive: false)
        }
        return ProjectEnvironmentSetToolResponse(
            toolchain: checked.toolchain,
            sdk: checked.sdk,
            changed: edit.changed,
            warnings: checked.diagnostics.filter { $0.severity == "warning" }.map(\.message),
        )
    }

    /// Runs `body` until it answers or the call is cancelled: a stop does
    /// not wait for a long wait on another conversation to run out.
    static func untilCancelled<T: Sendable>(
        _ cancellation: CancellationHandle?,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        let task = Task { try await body() }
        let registration = cancellation?.onCancel { _ in task.cancel() }
        defer { registration?.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func text(_ string: String) -> AgentToolResult {
        AgentToolResult(content: [.text(TextContent(text: string))])
    }

    private func json(_ value: some Encodable) -> AgentToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return text(String(decoding: data, as: UTF8.self))
    }
}
