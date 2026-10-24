import ApelinCore
import ApelinProtocol
import Foundation

/// Whether an `approvalRequested` is for a command that runs as root. The
/// host writes the command under its own `detail.rootCommand` key (never the
/// ordinary `detail.command`), so a root request is told apart by that key
/// alone; the card then marks it and Approve checks the device owner first.
/// The command itself is read from the request's `arguments` like any tool's
/// (`ToolCallDetail`), so it reads the same on the card and in the trace.
enum RootApprovalText {
    static func isRoot(_ payload: JSONValue?) -> Bool {
        payload?["detail"]?[RunCodeApproval.rootCommandDetail] != nil
    }
}
