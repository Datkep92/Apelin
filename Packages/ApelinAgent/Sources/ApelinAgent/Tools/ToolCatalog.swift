import struct ApelinCore.MemoryStore
import enum ApelinProtocol.BuildBootstrap
import Foundation
import KWWKAI

/// How much a tool can do, which decides how the approval gate treats it.
public enum ToolRisk: String, Sendable, Hashable, Codable {
    /// Reads inside the project, a registered SDK, or a bounded host view.
    case readOnly
    /// Writes project content or the agent's bounded memory library.
    case writeProject
    /// Runs something, changes the system, or acts on the UI.
    case system
}

/// The local tools of §7 — exactly these, no others.
public enum AgentToolName: String, Sendable, Hashable, Codable, CaseIterable {
    case writeFile = "write_file"
    case patchFile = "patch_file"
    case createFile = "create_file"
    case readFile = "read_file"
    case list
    case grep
    case find
    case runCode = "run_code"
    case analyzeFramework = "analyze_framework"
    case frameworkHeader = "framework_header"
    case build
    case install
    case removePackage = "remove_package"
    case respring
    case confirmLoaded = "confirm_loaded"
    case readLogs = "read_logs"
    case listCrashes = "list_crashes"
    case readCrash = "read_crash"
    case symbolicateCrash = "symbolicate_crash"
    case captureScreen = "capture_screen"
    case readUITree = "read_ui_tree"
    case uiAction = "ui_action"
    case memoryList = "memory_list"
    case memorySave = "memory_save"
    case memoryDelete = "memory_delete"
    case readSkill = "read_skill"
    case checkDistribution = "check_distribution"
    case projectTemplateList = "project_template_list"
    case projectCreate = "project_create"
    case gitStatus = "git_status"
    case gitDiff = "git_diff"
    case gitStage = "git_stage"
    case gitUnstage = "git_unstage"
    case gitCommit = "git_commit"
    case gitFetch = "git_fetch"
    case gitPull = "git_pull"
    case gitPush = "git_push"
    case gitClone = "git_clone"
    case gitSettings = "git_settings"
    case gitSetAuthor = "git_set_author"
    case gitSaveCredential = "git_save_credential"
    case gitRemoveCredential = "git_remove_credential"
    case conversationCreate = "conversation_create"
    case conversationSend = "conversation_send"
    case conversationList = "conversation_list"
    case conversationRead = "conversation_read"
    case conversationStop = "conversation_stop"
    case toolchainList = "toolchain_list"
    case sdkList = "sdk_list"
    case toolchainSetup = "toolchain_setup"
    case sdkImport = "sdk_import"
    case toolchainSelfTest = "toolchain_self_test"
    case projectEnvironmentSet = "project_environment_set"

    /// Only General Chat starts projects: it belongs to none, and a project's
    /// own chat has no reason to make another.
    public var isGeneralChatOnly: Bool {
        self == .projectTemplateList || self == .projectCreate
    }

    /// The git tools act on the session's project, which General Chat does
    /// not have: the host resolves a project under `Projects/` or refuses.
    /// So does the switch of the project's toolchain and SDK. The
    /// conversation tools reach General Chat too, naming a project there.
    public var isProjectOnly: Bool {
        switch self {
        case .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit,
             .gitFetch, .gitPull, .gitPush, .gitClone, .projectEnvironmentSet:
            true
        default:
            false
        }
    }

    /// Optional parameters whose empty value is an instruction, kept by
    /// `ToolArguments.normalized`: an empty author field clears it.
    var argumentsWhereEmptyMeansSomething: Set<String> {
        self == .gitSetAuthor ? ["name", "email"] : []
    }

    /// The conversation tools, which may name another project.
    public var isConversation: Bool {
        switch self {
        case .conversationCreate, .conversationSend, .conversationList, .conversationRead, .conversationStop: true
        default: false
        }
    }

    public var risk: ToolRisk {
        switch self {
        // The project's own repository: its index, commits and the refs a
        // fetch, pull or clone brings in. Nothing leaves the device.
        // Another conversation of the project works under the same approval
        // mode, so its own risky steps still ask the user. The project's
        // toolchain and SDK are a field of its apelin-project.json, which
        // the file tools edit too; only registered, compatible ones go in.
        case .writeFile, .patchFile, .createFile, .memorySave, .memoryDelete, .projectCreate,
             .gitStage, .gitUnstage, .gitCommit, .gitFetch, .gitPull, .gitClone,
             .conversationCreate, .conversationSend, .conversationStop, .projectEnvironmentSet:
            .writeProject
        case .readFile, .list, .grep, .find, .analyzeFramework, .frameworkHeader,
             .confirmLoaded, .readLogs, .listCrashes, .readCrash, .symbolicateCrash,
             .captureScreen, .readUITree, .memoryList, .readSkill, .checkDistribution,
             .projectTemplateList, .gitStatus, .gitDiff, .gitSettings,
             .conversationList, .conversationRead, .toolchainList, .sdkList:
            .readOnly
        // A push publishes commits with the user's credential; the author and
        // the credentials are the device's, for every project. A toolchain
        // or an SDK is installed on the device for every project, and the
        // self-test runs the toolchain's compilers and their output.
        case .runCode, .build, .install, .removePackage, .respring, .uiAction, .gitPush,
             .gitSetAuthor, .gitSaveCredential, .gitRemoveCredential,
             .toolchainSetup, .sdkImport, .toolchainSelfTest:
            .system
        }
    }

    /// Read tools whose output is sensitive (the screen, the UI tree): read
    /// only, but not let through by default — §7 configures them apart.
    public var isSensitiveRead: Bool {
        self == .captureScreen || self == .readUITree
    }

    public var summary: String {
        switch self {
        case .writeFile: "Create a file or replace its whole content, inside the project."
        case .patchFile: "Replace an exact snippet of a project file with new text; returns a diff. The snippet must occur exactly once unless replace_all is set."
        case .createFile: "Create a new project file; fails if it already exists."
        case .readFile: "Read a project file, optionally a range of lines."
        case .list: "List a project folder."
        case .grep: "Search project files with a regular expression."
        case .find: "Find project files whose names match a glob."
        case .runCode: "Run a command or script in the project as mobile. Pass argv for a plain command, command for shell text, or script with an interpreter."
        case .analyzeFramework: "Summarise a framework of the registered SDK from its .tbd and headers: install name, architectures, exported symbols and Objective-C classes."
        case .frameworkHeader: "Read one header of a framework in the registered SDK."
        case .build: "Build the project; returns structured diagnostics and artifacts with their digests."
        case .install: "Install a built package artifact through the system installer; returns the transaction and installation record."
        case .removePackage: "Remove a package Apelin built and installed, by its installation record id."
        case .respring: "Restart SpringBoard."
        case .confirmLoaded: "Check that a build is loaded in its target process by its marker log line, and whether its filter selects the target. Pass respring: true for a SpringBoard tweak: the marker is logged once at launch and only seen while listening."
        case .readLogs: "Read recent system log lines for a process or subsystem, bounded."
        case .listCrashes: "List crash report ids, newest first."
        case .readCrash: "Read a crash report by id."
        case .symbolicateCrash: "Symbolicate a crash report against the project's matching dSYM and rank suspects."
        case .captureScreen: "Take a screenshot of the device or a target."
        case .readUITree: "Read the UI element tree of the foreground app or a target."
        case .uiAction: "Perform one UI action: tap, tap an element, type text, swipe, or press a button."
        case .memoryList: "Read saved user preferences and facts for all chats and this project, with their current revision."
        case .memorySave: "Create or update a concise durable memory. Read memory_list first and supply its revision; never overwrite a user's correction or recreate a deleted memory from older context."
        case .memoryDelete: "Delete a memory that is outdated or that the user asks to forget. Read memory_list first and supply its revision."
        case .readSkill: "Read a skill's full instructions by name, or one file from its folder."
        case .projectTemplateList: "List the templates a new project can start from, with each template's id, kind and the parameters it asks for."
        case .projectCreate: "Create a new project from a template id from project_template_list. Apelin fills the identifiers, toolchain and SDK; pass values only for parameters the user cares about. The project appears in the Projects menu with its link; this chat stays General Chat and its file tools do not reach it, so hand the work on with conversation_create naming the project."
        case .gitStatus: "Show the project repository's branch, HEAD commit and changed files."
        case .gitDiff: "Show a unified diff of the worktree against the index, or with staged: true of the index against HEAD; optionally one path."
        case .gitStage: "Stage project files for the next commit."
        case .gitUnstage: "Take project files out of the index, keeping their changes."
        case .gitCommit: "Commit the staged changes locally. The author is the one set in Apelin's settings."
        case .gitFetch: "Fetch a remote's branches into its remote-tracking refs; the worktree is left alone."
        case .gitPull: "Fetch, then fast-forward the checked-out branch to its upstream. Never merges or rebases; a diverged branch or a local change in the way fails and changes nothing."
        case .gitPush: "Push a branch (default the checked-out one) to the branch of the same name on a remote (default origin). Never forced; a rejected update fails."
        case .gitClone: "Import a repository into this workspace over HTTPS: origin is set to url, and branch (default the remote's) checked out without overwriting files already there."
        case .gitSettings: "Read Apelin's git settings: the commit author, and the hosts with a saved HTTPS credential and their usernames. Tokens are never shown."
        case .gitSetAuthor: "Set the commit author Apelin uses for every project; an empty field is cleared."
        case .gitSaveCredential: "Save the HTTPS credential for one host, replacing any it had: a username and a personal access token the user gave you. It is kept in the device's keychain and offered only to remotes on exactly that host."
        case .gitRemoveCredential: "Remove the saved HTTPS credential for one host."
        case .checkDistribution: "Before a distribution build, list what the package should not carry yet: the template's name, description, author or first version, a local identifier, an app without an icon, a version already packaged for the target, and any error that would stop the build. A workspace's package is checked by its release build instead."
        case .conversationCreate: "Open another conversation, in this project or the one project names, with a first message, and return at once with its session id and link. Another agent works on it in parallel, under the same approval mode, and the user sees it in the sidebar. Collect its answer with conversation_read."
        case .conversationSend: "Send a message to another conversation, as if the user typed it; it waits there if that conversation is busy. Name its project with project when it is not this one. Read the answer with conversation_read."
        case .conversationList: "List the conversations of this project, or of the one project names: session id, link, title, state (open, waitingForApproval or ended), the conversation that opened each, and when it was last active."
        case .conversationRead: "Read a conversation of this project, or of the one project names: its state (running, waitingForApproval, idle or ended), the assistant's messages after after_seq, the approvals it is waiting on, and last_seq to pass as after_seq next time. With wait_seconds, wait until it finishes a turn after after_seq, asks for approval, or ends."
        case .conversationStop: "Stop the turn a conversation you opened is running. With close: true, also end the conversation and free its place; the user can still reopen it from the sidebar."
        case .toolchainList: "List the toolchains set up on this device (id, Command Line Tools version, components, the newest SDK each reads, self-test results) and the releases Apelin can set up from Apple's catalog, each with its download size, requirements and why this device cannot take it, if so; and which toolchain this project binds."
        case .sdkList: "List the iPhoneOS SDKs registered on this device and the ones the enabled SDK sources offer, each with the registered toolchains that read it; and which SDK this project binds."
        case .toolchainSetup: "Set up a Command Line Tools release from toolchain_list on this device: Apple's package is downloaded, adapted, installed as a package and self-tested, importing a compatible SDK first if none is registered. Long; asks the user in Strict mode. Then bind it with project_environment_set."
        case .sdkImport: "Import an iPhoneOS SDK an enabled source offers (sdk_list's available) onto this device: one branch is fetched, checked and registered. Asks the user in Strict mode. Then bind it with project_environment_set."
        case .toolchainSelfTest: "Run a registered toolchain's self-test again: small programs are compiled, signed and run for each language and architecture, and the results recorded. A failure is reported, never unregistered."
        case .projectEnvironmentSet: "Switch this project to a registered toolchain and/or SDK (ids from toolchain_list and sdk_list). The switch is checked first as projectCheck checks a project, and an incompatible pair, such as an SDK newer than the toolchain reads, is refused with that reason; then apelin-project.json is rewritten with the registry's digests."
        }
    }

    public var parameters: JSONValue {
        switch self {
        case .memoryList, .projectTemplateList, .gitStatus, .gitSettings, .toolchainList, .sdkList:
            Schema.object([:], required: [])
        case .conversationList:
            Schema.object([
                "project": Self.projectParameter,
            ], required: [])
        case .conversationCreate:
            Schema.object([
                "prompt": Schema.string("The first message, which the other agent reads as the user's: the task, the files involved, what to deliver, and what to leave alone."),
                "title": Schema.string("A short name for the sidebar, in the user's language."),
                "project": Self.projectParameter,
            ], required: ["prompt"])
        case .conversationSend:
            Schema.object([
                "session_id": Schema.string("Session id from conversation_create or conversation_list."),
                "text": Schema.string("The message, which that agent reads as the user's."),
                "project": Self.projectParameter,
            ], required: ["session_id", "text"])
        case .conversationRead:
            Schema.object([
                "session_id": Schema.string("Session id from conversation_create or conversation_list."),
                "after_seq": Schema.integer("Only messages after this point: last_seq from the previous read. Omit for the whole conversation."),
                "wait_seconds": Schema.integer("Wait up to this long, 0 to \(ConversationReadToolRequest.maximumWaitSeconds), for a turn after after_seq to finish. Default 0."),
                "project": Self.projectParameter,
            ], required: ["session_id"])
        case .toolchainSetup:
            Schema.object([
                "version": Schema.string("A release from toolchain_list's available, e.g. 16.4. Omit for the newest this device can take."),
                "product_id": Schema.string("Or the release's product id from toolchain_list."),
                "swift": Schema.boolean("Also set up Swift, where the release offers it on this device. Default false."),
            ], required: [])
        case .sdkImport:
            Schema.object([
                "version": Schema.string("An SDK version from sdk_list's available, e.g. 17.5."),
                "source": Schema.string("The source's name from sdk_list; omit for the first enabled source that offers the version."),
            ], required: ["version"])
        case .toolchainSelfTest:
            Schema.object([
                "toolchain_id": Schema.string("A registered toolchain's id from toolchain_list."),
            ], required: ["toolchain_id"])
        case .projectEnvironmentSet:
            Schema.object([
                "toolchain_id": Schema.string("A registered toolchain's id; omit to keep the project's."),
                "sdk_id": Schema.string("A registered SDK's id; omit to keep the project's."),
            ], required: [])
        case .conversationStop:
            Schema.object([
                "session_id": Schema.string("Session id of a conversation you opened."),
                "close": Schema.boolean("Also end the conversation, freeing its place."),
            ], required: ["session_id"])
        case .gitSetAuthor:
            Schema.object([
                "name": Schema.string("Author name; empty clears it."),
                "email": Schema.string("Author email; empty clears it."),
            ], required: [])
        case .gitSaveCredential:
            Schema.object([
                "host": Schema.string("Host name, with :port only if the remote URL names one, e.g. github.com. No scheme or path."),
                "username": Schema.string("The account's username."),
                "token": Schema.string("The personal access token, used as the HTTPS password."),
            ], required: ["host", "username", "token"])
        case .gitRemoveCredential:
            Schema.object([
                "host": Schema.string("Host name as git_settings lists it."),
            ], required: ["host"])
        case .gitDiff:
            Schema.object([
                "path": Schema.string("Path relative to the project root; omit for every change."),
                "staged": Schema.boolean("Diff the index against HEAD instead of the worktree against the index."),
            ], required: [])
        case .gitStage, .gitUnstage:
            Schema.object([
                "paths": .object([
                    "type": "array",
                    "items": .object(["type": "string"]),
                    "description": "Paths relative to the project root, taken literally.",
                ]),
            ], required: ["paths"])
        case .gitCommit:
            Schema.object([
                "message": Schema.string("The commit message: a short summary line, then a blank line and details if needed."),
            ], required: ["message"])
        case .gitFetch, .gitPull:
            Schema.object([
                "remote": Schema.string("Remote name; omit for origin."),
            ], required: [])
        case .gitPush:
            Schema.object([
                "remote": Schema.string("Remote name; omit for origin."),
                "branch": Schema.string("Local branch to push; omit for the checked-out one."),
            ], required: [])
        case .gitClone:
            Schema.object([
                "url": Schema.string("HTTPS URL of the repository, without credentials."),
                "branch": Schema.string("Branch to check out; omit for the remote's default."),
            ], required: ["url"])
        case .projectCreate:
            Schema.object([
                "template": Schema.string("Template id from project_template_list, e.g. wiki.qaq.apelin.dev.tweak/tweak."),
                "name": Schema.string("Project folder name: a few words, no slashes. It never changes later."),
                "values": .object([
                    "type": "object",
                    "description": "Template parameters by name, each a string, boolean or integer; omit for the defaults.",
                ]),
            ], required: ["template", "name"])
        case .memorySave:
            Schema.object([
                "revision": Schema.string("Exact current revision from memory_list."),
                "id": Schema.string("Existing record id to update. Omit to create a new record."),
                "title": Schema.string("Short title, at most \(MemoryStore.maximumTitleLength) characters."),
                "body": Schema.string("Concise durable fact or preference, at most \(MemoryStore.maximumBodyLength) characters. No secrets or temporary progress."),
                "scope": .object([
                    "type": "string",
                    "enum": ["global", "project"],
                    "description": "For new records: global for user preferences, project for this project's facts (default). Existing scope is preserved.",
                ]),
            ], required: ["revision", "title", "body"])
        case .checkDistribution:
            Schema.object([
                "bootstrap": .object([
                    "type": "string",
                    "enum": .array(BuildBootstrap.allCases.map { .string($0.rawValue) }),
                    "description": "The distribution target; omit to compare the version with both.",
                ]),
            ], required: [])
        case .readSkill:
            Schema.object([
                "name": Schema.string("Skill name from the skills list."),
                "file": Schema.string("A file in the skill's folder, relative to it; omit for the instructions."),
            ], required: ["name"])
        case .memoryDelete:
            Schema.object([
                "revision": Schema.string("Exact current revision from memory_list."),
                "id": Schema.string("Record id to delete."),
            ], required: ["revision", "id"])
        case .writeFile:
            Schema.object([
                "path": Schema.string("Path relative to the project root."),
                "content": Schema.string("The whole new content."),
            ], required: ["path", "content"])
        case .patchFile:
            Schema.object([
                "path": Schema.string("Path relative to the project root."),
                "old_text": Schema.string("Exact text to replace."),
                "new_text": Schema.string("Replacement text."),
                "replace_all": Schema.boolean("Replace every occurrence instead of exactly one."),
            ], required: ["path", "old_text", "new_text"])
        case .createFile:
            Schema.object([
                "path": Schema.string("Path relative to the project root."),
                "content": Schema.string("Content of the new file."),
            ], required: ["path", "content"])
        case .readFile:
            Schema.object([
                "path": Schema.string("Path relative to the project root."),
                "offset": Schema.integer("First line to return, 1-based."),
                "limit": Schema.integer("Number of lines to return."),
            ], required: ["path"])
        case .list:
            Schema.object([
                "path": Schema.string("Folder relative to the project root; omit for the root."),
                "depth": Schema.integer("How many levels to descend, 1 to 4. Default 1."),
            ], required: [])
        case .grep:
            Schema.object([
                "pattern": Schema.string("Regular expression (ICU syntax)."),
                "path": Schema.string("Folder or file to search, relative to the project root."),
                "glob": Schema.string("Only files whose name matches this glob, e.g. *.m"),
                "ignore_case": Schema.boolean("Case-insensitive match."),
                "max_results": Schema.integer("Maximum matching lines. Default 100."),
            ], required: ["pattern"])
        case .find:
            Schema.object([
                "pattern": Schema.string("Glob matched against file names, e.g. *.plist"),
                "path": Schema.string("Folder to search, relative to the project root."),
                "max_results": Schema.integer("Maximum paths. Default 200."),
            ], required: ["pattern"])
        case .runCode:
            Schema.object([
                "argv": .object([
                    "type": "array",
                    "items": .object(["type": "string"]),
                    "description": "A plain command: executable name, then arguments.",
                ]),
                "command": Schema.string("Shell text, when a plain argv is not enough."),
                "script": Schema.string("Script source, run by interpreter."),
                "interpreter": Schema.string("Interpreter for script: sh, bash, zsh, python3, perl."),
                "cwd": Schema.string("Working directory relative to the project root."),
                "timeout_seconds": Schema.integer("Timeout, default 120."),
            ], required: [])
        case .analyzeFramework:
            Schema.object([
                "framework": Schema.string("Framework name without extension, e.g. UIKit or SpringBoardServices."),
                "private": Schema.boolean("Look in PrivateFrameworks."),
                "sdk_id": Schema.string("Registered SDK id; omit for the project's SDK."),
                "symbol_filter": Schema.string("Only symbols containing this text."),
            ], required: ["framework"])
        case .frameworkHeader:
            Schema.object([
                "framework": Schema.string("Framework name without extension."),
                "header": Schema.string("Header file name, e.g. UIView.h; omit to list headers."),
                "private": Schema.boolean("Look in PrivateFrameworks."),
                "sdk_id": Schema.string("Registered SDK id; omit for the project's SDK."),
            ], required: ["framework"])
        case .build:
            Schema.object([
                "configuration": .object([
                    "type": "string",
                    "enum": ["debug", "release"],
                    "description": "Default debug.",
                ]),
                "bootstrap": .object([
                    "type": "string",
                    "enum": .array(BuildBootstrap.allCases.map { .string($0.rawValue) }),
                    "description": "Explicit distribution target; omit for the current device. Build both targets separately for distribution.",
                ]),
            ], required: [])
        case .install:
            Schema.object([
                "artifact_id": Schema.string("Package artifact id from build."),
                "artifact_digest": Schema.string("The artifact's digest from build."),
            ], required: ["artifact_id", "artifact_digest"])
        case .removePackage:
            Schema.object([
                "installation_id": Schema.string("Installation record id from install."),
            ], required: ["installation_id"])
        case .respring:
            Schema.object([:], required: [])
        case .confirmLoaded:
            Schema.object([
                "build_id": Schema.string("Build id from build."),
                "target": Schema.string("Process name or bundle id the tweak should load into, e.g. SpringBoard."),
                "respring": Schema.boolean("Start listening, then respring, then wait for the marker. Approved like respring."),
            ], required: ["build_id", "target"])
        case .readLogs:
            Schema.object([
                "process": Schema.string("Process name."),
                "subsystem": Schema.string("Log subsystem."),
                "since_seconds": Schema.integer("How far back, default 300, at most 3600."),
                "limit": Schema.integer("Maximum lines, default 200, at most 1000."),
            ], required: [])
        case .listCrashes:
            Schema.object([
                "process": Schema.string("Only this process."),
                "limit": Schema.integer("Maximum reports, default 20."),
            ], required: [])
        case .readCrash:
            Schema.object(["report_id": Schema.string("Report id from list_crashes.")], required: ["report_id"])
        case .symbolicateCrash:
            Schema.object([
                "report_id": Schema.string("Report id from list_crashes."),
                "build_id": Schema.string("Build whose dSYM to use; omit to match by image UUID."),
            ], required: ["report_id"])
        case .captureScreen:
            Schema.object(["target_id": Schema.string("Target; omit for the whole screen.")], required: [])
        case .readUITree:
            Schema.object([
                "target_id": Schema.string("Target; omit for the foreground app."),
                "max_depth": Schema.integer("Default 12."),
            ], required: [])
        case .uiAction:
            Schema.object([
                "target_id": Schema.string("Target; omit for the foreground app."),
                "action": .object([
                    "type": "string",
                    "enum": ["tap", "tap_element", "type_text", "swipe", "press_button"],
                ]),
                "x": Schema.number("Tap or swipe start x, points."),
                "y": Schema.number("Tap or swipe start y, points."),
                "to_x": Schema.number("Swipe end x."),
                "to_y": Schema.number("Swipe end y."),
                "element_id": Schema.string("Element id from read_ui_tree."),
                "text": Schema.string("Text to type."),
                "button": Schema.string("home, lock, volume_up or volume_down."),
            ], required: ["action"])
        }
    }

    /// The conversation tools' other project.
    static let projectParameter = Schema.string("Another project, by its projectID or folder name (project_create answers both): required in General Chat, omit for this project. A call that reaches another project asks the user in Strict mode.")
}

/// Every tool asks for a short reason, which the app shows while the call
/// runs. It is taken off the arguments before the tool, the approval gate or
/// the host sees them, so it never changes what runs or what was approved.
enum ToolReason {
    static let key = "reason"

    static func adding(to schema: JSONValue) -> JSONValue {
        guard case var .object(fields) = schema,
              case var .object(properties)? = fields["properties"] else { return schema }
        properties[key] = Schema.string("A few words on why you are making this call, shown to the user while it runs, e.g. \"Check how the tweak hooks SpringBoard\". Write it in the user's language.")
        fields["properties"] = .object(properties)
        var required: [JSONValue] = []
        if case let .array(existing)? = fields["required"] {
            required = existing
        }
        fields["required"] = .array(required + [.string(key)])
        return .object(fields)
    }

    static func removing(from arguments: JSONValue) -> JSONValue {
        guard case var .object(fields) = arguments else { return arguments }
        fields[key] = nil
        return .object(fields)
    }
}

/// Models fill optional parameters with `null`, `""`, `[]` or `{}` when they
/// mean to leave them out, and a tool that read those as given took the
/// wrong branch: `read_skill` with `file: ""` read a file instead of the
/// instructions, `run_code` with `argv: []` refused a command beside it,
/// `memory_save` with `id: ""` updated a record that does not exist. So an
/// empty optional argument is dropped before the tool, the gate or the host
/// sees it. A required one is left for the tool to refuse.
enum ToolArguments {
    static func normalized(_ arguments: JSONValue, for tool: AgentToolName) -> JSONValue {
        guard case var .object(fields) = arguments else { return arguments }
        let required = requiredKeys(tool.parameters).union(tool.argumentsWhereEmptyMeansSomething)
        for (key, value) in fields where !required.contains(key) && isEmpty(value) {
            fields[key] = nil
        }
        return .object(fields)
    }

    private static func requiredKeys(_ schema: JSONValue) -> Set<String> {
        guard case let .object(fields) = schema, case let .array(keys)? = fields["required"] else { return [] }
        return Set(keys.compactMap { key in
            if case let .string(name) = key {
                return name
            }
            return nil
        })
    }

    private static func isEmpty(_ value: JSONValue) -> Bool {
        switch value {
        case .null: true
        case let .string(string): string.isEmpty
        case let .array(values): values.isEmpty
        case let .object(object): object.isEmpty
        default: false
        }
    }
}

enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ])
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": "integer", "description": .string(description)])
    }

    static func number(_ description: String) -> JSONValue {
        .object(["type": "number", "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": "boolean", "description": .string(description)])
    }
}

// MARK: - Argument access

extension JSONValue {
    func argString(_ key: String) -> String? {
        guard case let .object(object) = self, case let .string(value)? = object[key] else { return nil }
        return value
    }

    /// The string argument, with an empty one read as not given.
    func argNonEmptyString(_ key: String) -> String? {
        argString(key).flatMap { $0.isEmpty ? nil : $0 }
    }

    func argInt(_ key: String) -> Int? {
        guard case let .object(object) = self else { return nil }
        switch object[key] {
        case let .int(value)?: return value
        case let .double(value)?: return Int(value)
        case let .string(value)?: return Int(value)
        default: return nil
        }
    }

    func argDouble(_ key: String) -> Double? {
        guard case let .object(object) = self else { return nil }
        switch object[key] {
        case let .int(value)?: return Double(value)
        case let .double(value)?: return value
        default: return nil
        }
    }

    func argBool(_ key: String) -> Bool? {
        guard case let .object(object) = self, case let .bool(value)? = object[key] else { return nil }
        return value
    }

    func argStrings(_ key: String) -> [String]? {
        guard case let .object(object) = self, case let .array(values)? = object[key] else { return nil }
        let strings = values.compactMap { value -> String? in
            if case let .string(string) = value {
                return string
            }
            return nil
        }
        return strings.count == values.count ? strings : nil
    }

    /// Canonical JSON text: sorted keys, no extra whitespace.
    var canonicalJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ToolArgumentError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

extension JSONValue {
    func requireString(_ key: String) throws -> String {
        guard let value = argString(key) else { throw ToolArgumentError("missing string argument '\(key)'") }
        return value
    }
}
