/// Every tool an agent session offers, by the name the model calls it and
/// the session's events record it. ApelinAgent says what each one does
/// (`ToolCatalog`); the session host and the app read the names from here,
/// so a rename reaches all three at once.
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
    case notifyUser = "notify_user"
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
}

public extension AgentToolName {
    /// The names earlier releases gave a tool, for the events and
    /// transcripts recorded then. None of them is a current name.
    static let legacyNames: [String: AgentToolName] = [:]

    /// The tool a recorded name means: a current name or one an earlier
    /// release used; nil for any other, such as an MCP server's.
    static func canonical(_ name: String) -> AgentToolName? {
        AgentToolName(rawValue: name) ?? legacyNames[name]
    }
}
