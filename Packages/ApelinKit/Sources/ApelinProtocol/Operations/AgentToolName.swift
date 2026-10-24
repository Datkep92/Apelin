/// Every tool an agent session offers, by the name the model calls it and
/// the session's events record it. ApelinAgent says what each one does
/// (`ToolCatalog`); the session host and the app read the names from here,
/// so a rename reaches all three at once.
///
/// A tool that acts on what Apelin keeps — its projects and templates, the
/// packages it installs, the device, toolchains and SDKs, conversations,
/// memory, skills, its settings — is `apelin_<scope>_<verb>`; a generic
/// verb on the session's own project is `<domain>_<verb>`: `file_*`,
/// `shell_run` and the repository's `git_*`. MCP tools keep kwwk's
/// `mcp__<server>__<tool>`.
public enum AgentToolName: String, Sendable, Hashable, Codable, CaseIterable {
    case writeFile = "file_write"
    case patchFile = "file_edit"
    case createFile = "file_create"
    case readFile = "file_read"
    case list = "file_list"
    case grep = "file_grep"
    case find = "file_find"
    case runCode = "shell_run"
    case analyzeFramework = "apelin_sdk_analyze_framework"
    case frameworkHeader = "apelin_sdk_read_header"
    case build = "apelin_project_build"
    case install = "apelin_package_install"
    case removePackage = "apelin_package_remove"
    case respring = "apelin_device_respring"
    case confirmLoaded = "apelin_package_confirm_loaded"
    case readLogs = "apelin_log_read"
    case listCrashes = "apelin_crash_list"
    case readCrash = "apelin_crash_read"
    case symbolicateCrash = "apelin_crash_symbolicate"
    case captureScreen = "apelin_screen_capture"
    case readUITree = "apelin_screen_read_tree"
    case uiAction = "apelin_screen_interact"
    case memoryList = "apelin_memory_list"
    case memorySave = "apelin_memory_save"
    case memoryDelete = "apelin_memory_delete"
    case readSkill = "apelin_skill_read"
    case notifyUser = "apelin_notification_send"
    case checkDistribution = "apelin_project_check_distribution"
    case projectTemplateList = "apelin_template_list"
    case projectCreate = "apelin_project_create"
    case gitStatus = "git_status"
    case gitDiff = "git_diff"
    case gitStage = "git_stage"
    case gitUnstage = "git_unstage"
    case gitCommit = "git_commit"
    case gitFetch = "git_fetch"
    case gitPull = "git_pull"
    case gitPush = "git_push"
    case gitClone = "git_clone"
    case gitSettings = "apelin_git_read_settings"
    case gitSetAuthor = "apelin_git_set_author"
    case gitSaveCredential = "apelin_git_save_credential"
    case gitRemoveCredential = "apelin_git_remove_credential"
    case conversationCreate = "apelin_conversation_create"
    case conversationSend = "apelin_conversation_send"
    case conversationList = "apelin_conversation_list"
    case conversationRead = "apelin_conversation_read"
    case conversationStop = "apelin_conversation_stop"
    case toolchainList = "apelin_toolchain_list"
    case sdkList = "apelin_sdk_list"
    case toolchainSetup = "apelin_toolchain_setup"
    case sdkImport = "apelin_sdk_import"
    case toolchainSelfTest = "apelin_toolchain_self_test"
    case projectEnvironmentSet = "apelin_project_set_environment"
}

public extension AgentToolName {
    /// The names earlier builds gave a tool (0.1.8 and before, and
    /// `notify_user` after it), for the events and transcripts recorded
    /// then. None of them is a current name.
    static let legacyNames: [String: AgentToolName] = [
        "write_file": .writeFile,
        "patch_file": .patchFile,
        "create_file": .createFile,
        "read_file": .readFile,
        "list": .list,
        "grep": .grep,
        "find": .find,
        "run_code": .runCode,
        "analyze_framework": .analyzeFramework,
        "framework_header": .frameworkHeader,
        "build": .build,
        "install": .install,
        "remove_package": .removePackage,
        "respring": .respring,
        "confirm_loaded": .confirmLoaded,
        "read_logs": .readLogs,
        "list_crashes": .listCrashes,
        "read_crash": .readCrash,
        "symbolicate_crash": .symbolicateCrash,
        "capture_screen": .captureScreen,
        "read_ui_tree": .readUITree,
        "ui_action": .uiAction,
        "memory_list": .memoryList,
        "memory_save": .memorySave,
        "memory_delete": .memoryDelete,
        "read_skill": .readSkill,
        "notify_user": .notifyUser,
        "check_distribution": .checkDistribution,
        "project_template_list": .projectTemplateList,
        "project_create": .projectCreate,
        "git_settings": .gitSettings,
        "git_set_author": .gitSetAuthor,
        "git_save_credential": .gitSaveCredential,
        "git_remove_credential": .gitRemoveCredential,
        "conversation_create": .conversationCreate,
        "conversation_send": .conversationSend,
        "conversation_list": .conversationList,
        "conversation_read": .conversationRead,
        "conversation_stop": .conversationStop,
        "toolchain_list": .toolchainList,
        "sdk_list": .sdkList,
        "toolchain_setup": .toolchainSetup,
        "sdk_import": .sdkImport,
        "toolchain_self_test": .toolchainSelfTest,
        "project_environment_set": .projectEnvironmentSet,
    ]

    /// The tool a recorded name means: a current name or one an earlier
    /// release used; nil for any other, such as an MCP server's.
    static func canonical(_ name: String) -> AgentToolName? {
        AgentToolName(rawValue: name) ?? legacyNames[name]
    }
}
