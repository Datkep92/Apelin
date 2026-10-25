import ApelinCore
import ApelinProtocol
import Foundation

/// What a pending approval's card says under its title, from the session's
/// `approvalRequested` and the call's own `toolCall`: why the agent made the
/// call (its `reason`), why the gate asks, a changed description's diff,
/// then the arguments by name (`ToolCallDetail`). A shell_run's argv reads
/// as the command line (`CommandLineText`). For a command as root the red
/// line on the card already says what the gate's sentence and the `root`
/// argument would, so both are left out. Display only: the approval stays
/// bound to what the host reads, `detail.command` or `detail.rootCommand`
/// and the working directory.
enum ApprovalCardText {
    /// Whether an `approvalRequested` is for a command that runs as root: the
    /// host binds such an approval to its own `detail.rootCommand` key,
    /// never the ordinary `detail.command`, so the key alone tells them apart.
    static func isRoot(_ payload: JSONValue?) -> Bool {
        payload?["detail"]?[RunCodeApproval.rootCommandDetail] != nil
    }

    /// `callReason`: the reason the agent gave on the call's `toolCall`.
    static func detail(_ payload: JSONValue?, title: String, callReason: String?) -> String {
        let root = isRoot(payload)
        let arguments = payload?["arguments"]?.stringValue.map {
            argumentsText($0, payload: payload, title: title, root: root)
        }
        return [
            callReason,
            root ? nil : payload?["reason"]?.stringValue,
            payload?["detail"]?["descriptionChanged"]?["diff"]?.stringValue,
            arguments,
        ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The arguments by name. For a shell_run, the command and directory are
    /// the ones the approval is bound to — the request's `detail.rootCommand`
    /// or `detail.command` and its `workingDirectory` — wherever it names
    /// them, so the card never shows one command while approving another;
    /// an argv reads as its command line, and a root card's `root` flag is
    /// left out.
    static func argumentsText(_ json: String, payload: JSONValue?, title: String, root: Bool) -> String {
        guard AgentToolName.canonical(payload?["tool"]?.stringValue ?? "") == .shellRun,
              case var .object(values)? = try? JSONCoding.decode(JSONValue.self, from: Data(json.utf8))
        else { return ToolCallDetail(detail: json, title: title).text }
        if root {
            values["root"] = nil
        }
        let bound = payload?["detail"]?[root ? RunCodeApproval.rootCommandDetail : "command"]
        if let bound, let shown = boundCommand(bound) {
            for key in ["argv", "command", "script", "interpreter"] {
                values[key] = nil
            }
            values.merge(shown) { _, bound in bound }
        } else if case let .array(items)? = values["argv"] {
            let words = items.compactMap(\.stringValue)
            if words.count == items.count {
                values["argv"] = .string(CommandLineText.quoted(words))
            }
        }
        if let directory = payload?["workingDirectory"]?.stringValue {
            values["cwd"] = directory.isEmpty || directory == "." ? nil : .string(directory)
        }
        guard let encoded = try? JSONCoding.encode(JSONValue.object(values)) else {
            return ToolCallDetail(detail: json, title: title).text
        }
        return ToolCallDetail(detail: String(decoding: encoded, as: UTF8.self), title: title).text
    }

    /// A bound invocation, in the shape apelin-agent writes it
    /// (`RunCodeInvocation`'s synthesized Codable), as the arguments it came
    /// from: an argv as its command line, shell text as `command`, a script
    /// with its interpreter. Nil for a shape it does not know.
    private static func boundCommand(_ invocation: JSONValue) -> [String: JSONValue]? {
        if case let .array(items)? = invocation["argv"]?["_0"] {
            let words = items.compactMap(\.stringValue)
            guard words.count == items.count else { return nil }
            return ["argv": .string(CommandLineText.quoted(words))]
        }
        if let text = invocation["shell"]?["_0"]?.stringValue {
            return ["command": .string(text)]
        }
        if let script = invocation["script"], let source = script["source"]?.stringValue,
           let interpreter = script["interpreter"]?.stringValue
        {
            return ["script": .string(source), "interpreter": .string(interpreter)]
        }
        return nil
    }
}

/// An argv as a POSIX shell reads it back, so two different argvs never
/// read the same: a word of ASCII letters, digits and `-_./=:@+,%` alone as
/// it is; any other word in single quotes, `'\''` for a quote, `''` for an
/// empty one; and one holding a character that does not show — a control,
/// a format character, a separator other than the space, a private-use or
/// unassigned code point — as `$'…'` with that character escaped.
enum CommandLineText {
    static func quoted(_ argv: [String]) -> String {
        argv.map(word).joined(separator: " ")
    }

    static func word(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(isPlain) {
            return word
        }
        guard word.unicodeScalars.contains(where: isHidden) else {
            return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        var escaped = "$'"
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\\": escaped += #"\\"#
            case "'": escaped += #"\'"#
            case "\n": escaped += #"\n"#
            case "\t": escaped += #"\t"#
            case "\r": escaped += #"\r"#
            case _ where isHidden(scalar):
                escaped += scalar.value > 0xFFFF
                    ? String(format: "\\U%08X", scalar.value)
                    : String(format: "\\u%04X", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped + "'"
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar)
            || "-_./=:@+,%".unicodeScalars.contains(scalar))
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            true
        case .spaceSeparator:
            scalar != " "
        default:
            false
        }
    }
}
