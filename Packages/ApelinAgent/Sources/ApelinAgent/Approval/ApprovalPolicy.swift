import enum ApelinProtocol.AgentToolName
import CryptoKit
import Foundation
import KWWKAI

/// The user-editable presets of Confirm mode, kept in the app's settings and
/// handed to the session when it opens. No tool can change them: the agent
/// has no write path to settings, and the session holds its own copy.
public struct ApprovalPresets: Sendable, Hashable, Codable {
    /// Read tools that run without asking. Only read-only tools count; a
    /// system tool named here is ignored.
    public var readTools: Set<AgentToolName>
    /// System tools that run without asking. Only `apelin_device_respring` and
    /// `apelin_screen_interact` can be preset; build and install follow the digest rule,
    /// shell_run follows `commands`, and package removal always asks.
    public var systemTools: Set<AgentToolName>
    public var commands: [CommandPreset]

    public init(readTools: Set<AgentToolName>, systemTools: Set<AgentToolName>, commands: [CommandPreset]) {
        self.readTools = readTools
        self.systemTools = systemTools
        self.commands = commands
    }

    /// Every read tool except the screen and the UI tree; respring; a few
    /// read-only commands that stay inside the project.
    public static let `default` = ApprovalPresets(
        readTools: Set(AgentToolName.allCases.filter { $0.risk == .readOnly && !$0.isSensitiveRead }),
        systemTools: [.deviceRespring],
        commands: [
            CommandPreset(name: "ls", executable: "ls"),
            CommandPreset(name: "cat", executable: "cat"),
            CommandPreset(name: "head", executable: "head"),
            CommandPreset(name: "tail", executable: "tail"),
            CommandPreset(name: "wc", executable: "wc"),
            CommandPreset(name: "file", executable: "file"),
            CommandPreset(name: "stat", executable: "stat"),
            CommandPreset(name: "plutil -p", executable: "plutil", argumentPrefix: ["-p"]),
            CommandPreset(name: "git status", executable: "git", argumentPrefix: ["status"]),
            CommandPreset(name: "git diff", executable: "git", argumentPrefix: ["diff"]),
            CommandPreset(name: "git log", executable: "git", argumentPrefix: ["log"]),
        ],
    )
}

/// What the gate knows about one call, gathered before deciding.
public struct InvocationFacts: Sendable, Hashable {
    public enum PathCheck: Sendable, Hashable {
        case inside
        case outside(String)
    }

    public enum Tool: Sendable, Hashable {
        case local(AgentToolName)
        /// A tool from an MCP server; always treated as a system tool.
        case mcp(String)
    }

    public var tool: Tool
    public var pathCheck: PathCheck?
    public var command: RunCodeInvocation?
    /// For build (`.build`) and install (`.packaging`).
    public var description: DescriptionState?
    /// For apelin_package_remove: the installation record it removes.
    public var installationID: String?
    /// For git_push: where it pushes, and what.
    public var push: GitPushTarget?
    /// For the git settings tools: what they change, in words, without a
    /// token ("the commit author", "the credential for github.com").
    public var gitSettings: String?
    /// For shell_run: its working directory, relative to the project root,
    /// which a preset's path arguments are read from.
    public var workingDirectory: String
    /// For apelin_toolchain_setup: the release, resolved in Apple's catalog before
    /// asking, and sent by product ID.
    public var toolchainSetup: ToolchainSetupApproval?
    /// For apelin_sdk_import: the source and branch, resolved before asking.
    public var sdkImport: SDKImportApproval?
    /// For a conversation tool that names another project than the
    /// session's: what it does there.
    public var otherProject: OtherProjectApproval?
    /// That project, as the backend resolved it, which the call is sent to.
    public var targetProject: ProjectIdentity?
    /// For build in a workspace: what it builds, which runs the workspace's
    /// own script.
    public var externalBuild: ExternalBuildApproval?

    public init(
        tool: Tool,
        pathCheck: PathCheck? = nil,
        command: RunCodeInvocation? = nil,
        description: DescriptionState? = nil,
        installationID: String? = nil,
        push: GitPushTarget? = nil,
        gitSettings: String? = nil,
        workingDirectory: String = ".",
        toolchainSetup: ToolchainSetupApproval? = nil,
        sdkImport: SDKImportApproval? = nil,
        otherProject: OtherProjectApproval? = nil,
    ) {
        self.tool = tool
        self.pathCheck = pathCheck
        self.command = command
        self.description = description
        self.installationID = installationID
        self.push = push
        self.gitSettings = gitSettings
        self.workingDirectory = workingDirectory
        self.toolchainSetup = toolchainSetup
        self.sdkImport = sdkImport
        self.otherProject = otherProject
    }
}

/// The remote a push goes to and the local branch it sends.
public struct GitPushTarget: Sendable, Hashable {
    public var remote: String
    /// nil when no branch is checked out; the host then refuses the push.
    public var branch: String?

    public init(remote: String, branch: String?) {
        self.remote = remote
        self.branch = branch
    }
}

public enum GateVerdict: Sendable, Hashable {
    case allow(ApprovalEvidence)
    case ask(reason: String, detail: ApprovalDetail)
    case deny(String)
}

/// The decision table of §7, as a pure function of mode, presets and the
/// facts of one call. The session host runs the same rules again on its
/// side; this copy is what makes the agent wait.
public struct ApprovalPolicy: Sendable, Hashable {
    public var mode: ApprovalMode
    public var presets: ApprovalPresets

    public init(mode: ApprovalMode, presets: ApprovalPresets = .default) {
        self.mode = mode
        self.presets = presets
    }

    public func evaluate(_ facts: InvocationFacts, root: ScopedRoot) -> GateVerdict {
        // Leaving the project is refused in both modes: it is outside every
        // tool's capability, not a matter of asking.
        if case let .outside(path)? = facts.pathCheck {
            return .deny("\(path) is outside the project")
        }
        if mode == .relaxed {
            return .allow(.relaxed)
        }

        switch facts.tool {
        case let .mcp(name):
            return .ask(reason: "\(name) is a tool from an MCP server. Review it before running.", detail: .none)
        case let .local(tool):
            return evaluateConfirm(tool, facts: facts, root: root)
        }
    }

    private func evaluateConfirm(_ tool: AgentToolName, facts: InvocationFacts, root: ScopedRoot) -> GateVerdict {
        // A conversation call into another project asks every time, naming
        // the project and what it sends there.
        if tool.isConversation, let reach = facts.otherProject {
            return .ask(reason: Self.otherProjectReason(reach), detail: .otherProject(reach))
        }
        switch tool {
        case .fileWrite, .fileEdit, .fileCreate, .memorySave, .memoryDelete:
            return .allow(.notRequired)

        // A banner from Apelin to the user, never a preset to edit away:
        // it reads, writes and runs nothing, and it shows only while Apelin
        // is not in front, plain, bounded and a few per turn
        // (`AgentNoticeRules`). Asking first would defeat it: the user it
        // is for is not looking.
        case .notificationSend:
            return .allow(.notRequired)

        // A field of the project's own apelin-project.json, which the file
        // tools edit as well: only a registered, checked, compatible
        // toolchain or SDK goes in. The binding is not part of the build
        // description digest, so the next build does not ask for it.
        case .projectSetEnvironment:
            return .allow(.notRequired)

        // Installed on the device for every project, a toolchain through
        // Irisin: every setup and import asks, naming what is downloaded.
        case .toolchainSetup:
            guard let setup = facts.toolchainSetup else {
                return .ask(reason: "The toolchain to set up could not be identified.", detail: .none)
            }
            return .ask(reason: Self.setupReason(setup), detail: .toolchainSetup(setup))

        case .sdkImport:
            guard let sdkImport = facts.sdkImport else {
                return .ask(reason: "The SDK to import could not be identified.", detail: .none)
            }
            return .ask(
                reason: "Imports the iPhoneOS \(sdkImport.version) SDK onto this device from \(sdkImport.source) (branch \(sdkImport.branch) of \(sdkImport.url)): one branch is downloaded, checked and registered for every project. Each import needs your approval.",
                detail: .sdkImport(sdkImport),
            )

        // Runs the toolchain's compilers and the programs they make, as
        // mobile, and records the results; it installs nothing.
        case .toolchainSelfTest:
            return .ask(
                reason: "Runs the toolchain's self-test again: small programs are compiled, signed and run as mobile, and the results recorded.",
                detail: .none,
            )

        // A new folder from a template: nothing in it runs, and its build
        // and packaging are the template's, which the host's ledger records.
        case .projectCreate:
            return .allow(.notRequired)

        // The project's own repository, changed in the project: like an
        // edit, and nothing leaves the device. A fetch, pull or clone
        // only brings commits in; pull never merges, clone never
        // overwrites.
        case .gitStage, .gitUnstage, .gitCommit, .gitFetch, .gitPull, .gitClone:
            return .allow(.notRequired)

        // Another conversation of the project, opened, sent to or stopped:
        // its agent runs under this session's mode, so whatever it does
        // that would ask, asks there.
        case .conversationCreate, .conversationSend, .conversationStop:
            return .allow(.notRequired)

        // Publishes commits with the user's credential: every push asks,
        // and the card names where it goes.
        case .gitPush:
            guard let target = facts.push else {
                return .ask(reason: "Where this push goes could not be read.", detail: .none)
            }
            let branch = target.branch ?? "the checked-out branch"
            return .ask(
                reason: "Pushing \(branch) to \(target.remote) publishes its commits. Each push needs your approval.",
                detail: .gitPush(remote: target.remote, branch: target.branch),
            )

        // The device's git settings, for every project: each change asks,
        // and a saved token is never on the card.
        case .gitSetAuthor, .gitSaveCredential, .gitRemoveCredential:
            let summary = facts.gitSettings ?? "a change to the git settings"
            return .ask(
                reason: "This changes \(summary) for every project. Each change needs your approval.",
                detail: .gitSettings(summary: summary),
            )

        case .fileRead, .fileList, .fileGrep, .fileFind, .sdkAnalyzeFramework, .sdkReadHeader,
             .packageConfirmLoaded, .logRead, .crashList, .crashRead, .crashSymbolicate,
             .screenCapture, .screenReadTree, .memoryList, .skillRead, .projectCheckDistribution,
             .templateList, .gitStatus, .gitDiff, .gitReadSettings,
             .conversationList, .conversationRead, .toolchainList, .sdkList:
            if presets.readTools.contains(tool) {
                return .allow(.preset(tool.rawValue))
            }
            return .ask(reason: "This action is not in your approved presets. Review it before running.", detail: .none)

        case .deviceRespring, .screenInteract:
            if presets.systemTools.contains(tool) {
                return .allow(.preset(tool.rawValue))
            }
            return .ask(reason: "This action changes this device. Review it before running.", detail: .none)

        case .shellRun:
            guard let command = facts.command else {
                return .ask(reason: "Apelin could not read this command. Review it before running.", detail: .none)
            }
            if case let .argv(argv) = command,
               let preset = presets.commands.first(where: {
                   $0.matches(argv, root: root, workingDirectory: facts.workingDirectory)
               })
            {
                return .allow(.preset(preset.name))
            }
            switch command {
            case .argv:
                return .ask(
                    reason: "This command is not in your approved presets. Review it before running.",
                    detail: .command(command),
                )
            case .shell:
                return .ask(
                    reason: "This command uses shell features such as pipes or redirection. Review it before running.",
                    detail: .command(command),
                )
            case .script: return .ask(reason: "Scripts require approval each time they run.", detail: .command(command))
            }

        case .projectBuild, .packageInstall:
            // A workspace's build runs its own script, code from the
            // repository: every build asks, and is never granted for the
            // session.
            if tool == .projectBuild, let build = facts.externalBuild {
                return .ask(
                    reason: "Runs this workspace's own build script, \(build.script), as mobile with the prepared toolchain: it can run any code in the repository. Each build of a workspace needs your approval.",
                    detail: .externalBuild(build),
                )
            }
            let kind: DescriptionKind = tool == .projectBuild ? .build : .packaging
            guard let state = facts.description else {
                return .ask(reason: "The \(kind.rawValue) description could not be checked.", detail: .none)
            }
            switch state.baseline {
            case .matchesTemplate: return .allow(.templateMatch(digest: state.digest))
            case .approved: return .allow(.digestApproved(digest: state.digest))
            case let .changed(diff):
                return .ask(
                    reason: "The \(kind.rawValue) description changed since the template or your last approval. Review the changes before continuing.",
                    detail: .descriptionChanged(kind: kind, digest: state.digest, diff: diff),
                )
            }

        case .packageRemove:
            // The session host grants the removal from this detail alone
            // (`allowRemoval`), so a request without it could never be spent.
            guard let installationID = facts.installationID else {
                return .ask(reason: "The package to remove could not be identified.", detail: .none)
            }
            return .ask(
                reason: "Removing a package requires your approval.",
                detail: .packageRemoval(installationID: installationID),
            )
        }
    }

    static func setupReason(_ setup: ToolchainSetupApproval) -> String {
        let components = setup.components.contains("swift") ? "C and Swift" : "C"
        let size = setup.sizeBytes.map {
            " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))"
        } ?? ""
        return "Sets up Command Line Tools \(setup.version) (\(components)) on this device: Apple's package\(size) is downloaded from Apple, adapted, installed as a package through Irisin for every project and self-tested; if no registered SDK fits it, one is imported from an enabled SDK source first. Each install needs your approval."
    }

    static func otherProjectReason(_ reach: OtherProjectApproval) -> String {
        // The whole text is in the call's arguments, which the card shows too.
        let full = reach.text ?? ""
        let text = full.count > 400 ? String(full.prefix(400)) + "…" : full
        let what = switch reach.action {
        case "create": "opens a conversation in the project \(reach.projectName) whose agent reads this as your message: “\(text)”"
        case "send": "sends a conversation of the project \(reach.projectName) this as your message: “\(text)”"
        case "list": "lists the conversations of the project \(reach.projectName)"
        default: "reads a conversation of the project \(reach.projectName)"
        }
        return "This \(what). Each call that reaches another project needs your approval."
    }
}

/// Binds an approval to tool, arguments, working directory, project, and
/// the description digest when there is one.
public enum ApprovalFingerprint {
    public static func make(
        tool: String,
        arguments: JSONValue,
        workingDirectory: String,
        projectID: String,
        digest: String?,
    ) -> String {
        let material: JSONValue = .object([
            "tool": .string(tool),
            "arguments": arguments,
            "cwd": .string(workingDirectory),
            "project": .string(projectID),
            "digest": digest.map { .string($0) } ?? .null,
        ])
        let hash = SHA256.hash(data: Data(material.canonicalJSON.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
