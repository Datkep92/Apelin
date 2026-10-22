import ApelinCore
import Foundation

/// Arguments as the task's events record them: the token git_save_credential
/// carries is replaced, so it reaches the host's keychain request and no
/// event, transcript or log. The model's own copy is the user's message.
public enum ToolArgumentRedaction {
    static let mask = "••••••••"

    public static func redacted(_ arguments: String, tool: String) -> String {
        guard tool == AgentToolName.gitSaveCredential.rawValue else { return arguments }
        guard case var .object(fields)? = try? JSONCoding.decode(JSONValue.self, from: Data(arguments.utf8)) else {
            // nothing readable to keep: none of it is shown
            return "{}"
        }
        if fields["token"] != nil {
            fields["token"] = .string(mask)
        }
        guard let data = try? JSONCoding.encode(JSONValue.object(fields)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
