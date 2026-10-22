import ApelinProtocol
import Foundation

/// One device-wide choice, synchronized to the receiving session on every send.
enum AgentPermissions {
    static var mode: ApprovalMode {
        get {
            UserDefaults.standard.string(forKey: "agent.permissionMode")
                .flatMap(ApprovalMode.init(rawValue:)) ?? .relaxed
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "agent.permissionMode") }
    }

    static func title(for mode: ApprovalMode) -> String {
        mode == .confirm ? String(localized: "Strict") : String(localized: "Relaxed")
    }

    static var explanation: String {
        String(localized: "Strict: asks before commands and sensitive changes. Relaxed: runs these operations without asking, within the app’s permissions. Each chat uses this setting when you send its next message.")
    }
}
