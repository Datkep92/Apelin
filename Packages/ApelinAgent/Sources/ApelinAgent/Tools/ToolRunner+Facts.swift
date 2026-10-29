import enum ApelinCore.ProjectDisplayName
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI

extension ToolRunner {
    func gatherFacts(_ tool: InvocationFacts.Tool, arguments: JSONValue) async throws -> InvocationFacts {
        guard case let .local(name) = tool else { return InvocationFacts(tool: tool) }
        var facts = InvocationFacts(tool: tool)
        switch name {
        case .fileWrite, .fileEdit, .fileCreate:
            let path = try arguments.requireString("path")
            // No project walk for .git files here: a git directory does not
            // change the gate's answer, and the tool's own resolution walks.
            facts.pathCheck = check { _ = try root.resolveForWrite(path, findingGitPointers: false) }
        case .fileRead:
            let path = try arguments.requireString("path")
            facts.pathCheck = check { _ = try root.resolveExisting(path) }
        case .fileList, .fileGrep, .fileFind:
            let path = arguments.argString("path") ?? "."
            facts.pathCheck = check { _ = try root.resolveExisting(path) }
        case .shellRun:
            facts.command = try CommandClassifier.classify(arguments)
            facts.runsAsRoot = arguments.argBool("root") ?? false
            let cwd = arguments.argString("cwd") ?? "."
            facts.pathCheck = root.mayReach(cwd) ? .inside : .outside(cwd)
            facts.workingDirectory = cwd
        case .projectBuild:
            if let script = ProjectBuildSystem.externalScript(in: root) {
                facts.externalBuild = ExternalBuildApproval(
                    projectID: project.id,
                    script: script,
                    configuration: arguments.argNonEmptyString("configuration") ?? "debug",
                    bootstrap: arguments.argNonEmptyString("bootstrap"),
                )
            } else {
                facts.description = try? await digests.state(of: .build, for: project)
            }
        case .packageInstall:
            // A workspace has no packaging description: the package it built
            // is judged by its own (apelin-build's ExternalBuild).
            if ProjectBuildSystem.read(in: root) == .external {
                let artifact = try arguments.requireString("artifact_id")
                guard let state = try? await digests.packagingState(ofArtifact: artifact, for: project) else {
                    throw ToolArgumentError("No build of this workspace made a package \(artifact): build it again with apelin_project_build, then install the artifact that build answers.")
                }
                facts.description = state
            } else {
                facts.description = try? await digests.state(of: .packaging, for: project)
            }
        case .packageRemove:
            facts.installationID = try arguments.requireString("installation_id")
        case .webFetch:
            // An address that would never be fetched is refused before
            // anyone is asked about it.
            _ = try WebFetch.target(arguments.requireString("url"))
        case .gitPush:
            // The branch the card names is the one pushed: an omitted one is
            // read now and sent explicitly.
            var branch = arguments.argNonEmptyString("branch")
            if branch == nil {
                let status = try? await backend.gitStatus(GitStatusToolRequest(context: HostCallContext(
                    sessionID: sessionID,
                    project: project,
                    toolCallID: "",
                    approval: .notRequired,
                )))
                branch = status?.branch
            }
            facts.push = GitPushTarget(remote: arguments.argNonEmptyString("remote") ?? "origin", branch: branch)
        case .gitSetAuthor:
            facts.gitSettings = "the commit author"
        case .gitSaveCredential:
            let host = arguments.argString("host") ?? ""
            // github.com is the user's Sign In with GitHub, never a token
            // passed through the conversation; refused before anyone is asked.
            guard host.trimmingCharacters(in: .whitespaces).lowercased() != "github.com" else {
                throw ToolArgumentError("github.com takes no token here: ask the user to sign in with Sign In with GitHub in Settings ▸ Git.")
            }
            let username = arguments.argString("username") ?? ""
            facts.gitSettings = "the credential for \(host) (user \(username))"
        case .gitRemoveCredential:
            facts.gitSettings = "the credential for \(arguments.argString("host") ?? "")"
        case .packageConfirmLoaded where arguments.argBool("respring") == true:
            // It resprings the device, so it is gated as respring is.
            facts.tool = .local(.deviceRespring)
        case .conversationCreate, .conversationSend, .conversationList, .conversationRead:
            try await gatherProjectReach(name, arguments: arguments, into: &facts)
        case .toolchainSetup:
            facts.toolchainSetup = try await setupToAsk(arguments)
        case .sdkImport:
            facts.sdkImport = try await importToAsk(arguments)
        case .projectRename:
            try await gatherRename(arguments, into: &facts)
        case .skillSave:
            facts.skillChange = try skillTools().change(saving: arguments)
        case .skillRemove:
            facts.skillChange = try skillTools().change(removing: arguments)
        case .projectSetEnvironment:
            facts.pathCheck = check { _ = try root.resolveForWrite(ProjectEnvironmentEdit.fileName, findingGitPointers: false) }
        default:
            break
        }
        return facts
    }

    /// The project a conversation call names, resolved before asking: none
    /// (or this one) keeps the call in the session's project; another one is
    /// what the card names and where the call goes. General Chat names one.
    private func gatherProjectReach(
        _ name: AgentToolName,
        arguments: JSONValue,
        into facts: inout InvocationFacts,
    ) async throws {
        guard let reference = arguments.argNonEmptyString("project") else {
            if project.isTemporary {
                throw ToolArgumentError("General Chat has no conversations of its own: name the project with project (its projectID or folder name, as apelin_project_list answers them)")
            }
            return
        }
        let target = try await backend.resolveProject(reference)
        guard target.id != project.id else { return }
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat's conversations are the user's alone") }
        facts.targetProject = target
        let action = switch name {
        case .conversationCreate: "create"
        case .conversationSend: "send"
        case .conversationList: "list"
        default: "read"
        }
        facts.otherProject = OtherProjectApproval(
            action: action,
            projectID: target.id,
            projectName: target.name.rawValue,
            sessionID: arguments.argNonEmptyString("session_id"),
            text: name == .conversationCreate ? arguments.argString("prompt")
                : name == .conversationSend ? arguments.argString("text") : nil,
        )
    }

    /// The project a rename names, resolved before asking: this session's
    /// when none is named (General Chat has none), else the one named,
    /// whose card says what it is called now and what it becomes.
    private func gatherRename(_ arguments: JSONValue, into facts: inout InvocationFacts) async throws {
        let name = try arguments.requireString("display_name").trimmingCharacters(in: .whitespaces)
        guard ProjectDisplayName.isValid(name) else {
            throw ToolArgumentError("The name is 1 to \(ProjectDisplayName.maximumLength) characters on one line.")
        }
        let target: ProjectIdentity
        if let reference = arguments.argNonEmptyString("project") {
            target = try await backend.resolveProject(reference)
        } else if project.isTemporary {
            throw ToolArgumentError("General Chat has no project of its own: name it with project (its projectID or folder name, as apelin_project_list answers them)")
        } else {
            target = project
        }
        guard !target.isTemporary else { throw ToolDeniedError(message: "a temporary chat has no project to rename") }
        facts.renamedProject = target
        guard target.id != project.id else { return }
        if arguments.argBool("automatic") == true {
            throw ToolArgumentError("automatic naming is for this conversation's own project; rename another only when the user asks, without automatic")
        }
        let listed = try? await backend.projects().projects.first { $0.projectID == target.id }
        facts.projectRename = ProjectRenameApproval(
            projectID: target.id,
            folder: target.name.rawValue,
            currentName: listed?.displayName ?? target.name.rawValue,
            displayName: name,
        )
    }

    /// The release a setup takes, resolved in Apple's catalog before asking:
    /// the version or product named, else the newest this device can take.
    /// One this device cannot take, or Swift where the release offers none,
    /// is refused here with the catalog's reason.
    private func setupToAsk(_ arguments: JSONValue) async throws -> ToolchainSetupApproval {
        let listed = try await backend.toolchains(context: probeContext)
        if let problem = listed.catalogProblem, listed.available.isEmpty {
            throw ToolDeniedError(message: "Apple's catalog could not be read: \(problem)")
        }
        let product: AvailableToolchain
        if let id = arguments.argNonEmptyString("product_id") {
            guard let match = listed.available.first(where: { $0.productID == id }) else {
                throw ToolArgumentError("no release \(id) in apelin_toolchain_list's available")
            }
            product = match
        } else if let version = arguments.argNonEmptyString("version") {
            guard let match = listed.available.first(where: { $0.version == version }) else {
                throw ToolArgumentError("no Command Line Tools \(version) in apelin_toolchain_list's available")
            }
            product = match
        } else {
            guard let newest = listed.available.first(where: { $0.unavailable == nil }) else {
                throw ToolDeniedError(message: "no release in Apple's catalog can be set up on this device")
            }
            product = newest
        }
        if let reason = product.unavailable {
            throw ToolDeniedError(message: "Command Line Tools \(product.version) cannot be set up here: \(reason)")
        }
        let swift = arguments.argBool("swift") ?? false
        if swift, product.swift == nil {
            throw ToolDeniedError(message: product.swiftUnavailable
                ?? "Command Line Tools \(product.version) offers no Swift on this device; set it up without Swift or choose another release")
        }
        let components = swift ? ["c", "swift"] : ["c"]
        if let installed = listed.installed.first(where: { record in
            record.version == product.version && components.allSatisfy(record.components.contains) && record.problem == nil
        }) {
            throw ToolArgumentError("Command Line Tools \(product.version) is already set up as \(installed.id); bind it with apelin_project_set_environment")
        }
        return ToolchainSetupApproval(
            productID: product.productID,
            version: product.version,
            components: components,
            sizeBytes: product.sizeBytes > 0 ? product.sizeBytes : nil,
        )
    }

    /// The source and branch an import takes, resolved before asking among
    /// what the enabled sources offer; the model never passes an address.
    private func importToAsk(_ arguments: JSONValue) async throws -> SDKImportApproval {
        let version = try arguments.requireString("version").trimmingCharacters(in: .whitespaces)
        let listed = try await backend.sdks(context: probeContext)
        if let registered = listed.installed.first(where: { $0.version == version }) {
            throw ToolArgumentError("iPhoneOS \(version) is already registered as \(registered.id); bind it with apelin_project_set_environment")
        }
        let source = arguments.argNonEmptyString("source")
        guard let offer = listed.available.first(where: {
            $0.version == version && (source == nil || $0.source == source)
        }) else {
            let problems = listed.sourceProblems.isEmpty ? "" : " (\(listed.sourceProblems.joined(separator: "; ")))"
            throw ToolArgumentError("no enabled source offers iPhoneOS \(version)\(source.map { " in \($0)" } ?? "")\(problems); apelin_sdk_list names what they offer")
        }
        return SDKImportApproval(source: offer.source, url: offer.sourceURL, branch: offer.branch, version: offer.version)
    }

    /// A context for reads made while gathering facts, before any approval.
    private nonisolated var probeContext: HostCallContext {
        HostCallContext(sessionID: sessionID, project: project, toolCallID: "", approval: .notRequired)
    }

    /// The project's repository for the first message's context: nil when
    /// it has none, or when the host has not answered within `seconds`,
    /// which is as long as the message waits for it.
    nonisolated func repositoryStatus(within seconds: Double) async -> GitStatusToolResponse? {
        let backend = backend
        let context = probeContext
        let answer = FirstAnswer<GitStatusToolResponse?>()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            Task { await answer.give(try? backend.gitStatus(GitStatusToolRequest(context: context))) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                answer.give(nil)
            }
        }
    }

    /// `.outside` when resolution refuses the path as leaving the project
    /// (including a symbolic link it will not write through); `.inside`
    /// otherwise — a missing file is the tool's error to report.
    private func check(_ resolve: () throws -> Void) -> InvocationFacts.PathCheck {
        do {
            try resolve()
            return .inside
        } catch let error as PathPolicyError {
            switch error {
            case let .outsideRoot(path), let .symlinkRefused(path): return .outside(path)
            case .embeddedNUL: return .outside("a path with a NUL byte")
            default: return .inside
            }
        } catch {
            return .inside
        }
    }
}

/// Resumes its continuation with the first value given, once.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Value, Never>?
    private var answered = false

    var continuation: CheckedContinuation<Value, Never>? {
        get { lock.withLock { waiting } }
        set { lock.withLock { waiting = newValue } }
    }

    func give(_ value: Value) {
        let continuation: CheckedContinuation<Value, Never>? = lock.withLock {
            guard !answered, let waiting else { return nil }
            answered = true
            self.waiting = nil
            return waiting
        }
        continuation?.resume(returning: value)
    }
}
