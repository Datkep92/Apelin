import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation

/// Rebuilds visible rows from ordered host events. Replays use the same row IDs.
struct ChatTranscript {
    var messages: [ChatMessage] = []
    var isWorking = false
    var approvalIDs: [UUID: String] = [:]
    private var thinking: Int?
    private var thinkingStarted: Date?
    private var assistant: Int?
    private var toolRows: [String: Int] = [:]
    /// The row the turn has shown nothing after yet: its prompt, or images a
    /// tool returned. A running summary stands in under it, under the id the
    /// next thought takes, so the one becomes the other with no gap.
    private var unanswered: UUID?

    /// `conversationTitle` names another conversation of the project by its
    /// session ID, for a message its agent sent. `sending` are messages sent
    /// and not echoed yet: each shows last, under its draft's id, until the
    /// host's `prompt` or `queued` event with that id takes its place.
    init(
        events: [TaskEvent],
        sending: [ComposerDraft] = [],
        conversationTitle: (String) -> String? = { _ in nil },
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) {
        // sent during a run and not taken by it yet: shown after everything
        // else until the run takes them, then in place like any message
        var queued: [ChatMessage] = []
        for event in events {
            let payload = event.payload
            let text = payload?["text"]?.stringValue ?? ""
            let id = Self.rowID("event:\(event.seq.rawValue)")
            switch event.kind {
            case "prompt", "steer":
                finishThinking(at: event.time)
                assistant = nil
                let messageID = Self.userMessageID(of: event) ?? id
                let files = (try? payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
                queued.removeAll { $0.id == messageID }
                if !messages.contains(where: { $0.id == messageID }) {
                    var message = ChatMessage(
                        id: messageID,
                        role: .user,
                        text: text,
                        attachments: files.compactMap(attachment),
                    )
                    message.sender = payload?["from"]?.stringValue.map { Self.senderLine(conversationTitle($0)) }
                    messages.append(message)
                }
                unanswered = messageID
                isWorking = true
            case "queued":
                guard let messageID = Self.userMessageID(of: event),
                      !messages.contains(where: { $0.id == messageID }), !queued.contains(where: { $0.id == messageID })
                else { break }
                let files = (try? payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
                var message = ChatMessage(
                    id: messageID,
                    role: .user,
                    text: text,
                    attachments: files.compactMap(attachment),
                )
                message.isQueued = true
                queued.append(message)
            case "queueDropped":
                let ids = Set((try? payload?["ids"]?.decode([UUID].self)) ?? [])
                queued.removeAll { ids.contains($0.id) }
            case "messageStarted":
                assistant = nil
                finishThinking(at: event.time)
                startThinking(id: id, at: event.time)
                isWorking = true
            case "thinking":
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
                if let thinking {
                    messages[thinking].text += text
                }
            case "toolCallPreparing":
                // The call shows only once its arguments are whole, so the
                // summary runs meanwhile. The message keeps its one text
                // row: its full text still comes in `message`.
                if thinking == nil {
                    startThinking(id: id, at: event.time)
                }
            case "text", "message":
                finishThinking(at: event.time)
                guard !text.isEmpty else { break }
                unanswered = nil
                if assistant == nil {
                    assistant = messages.count
                    messages.append(ChatMessage(id: id, role: .assistant, text: ""))
                }
                if let assistant {
                    if event.kind == "message" {
                        messages[assistant].text = text
                    } else {
                        messages[assistant].text += text
                    }
                }
            case "toolCall":
                finishThinking(at: event.time)
                assistant = nil
                unanswered = nil
                if let toolID = payload?["id"]?.stringValue {
                    toolRows[toolID] = messages.count
                    let name = payload?["tool"]?.stringValue ?? ""
                    let arguments = payload?["arguments"]?.stringValue
                    var row = ChatMessage(id: id, role: .tool, text: Self.toolTitle(name, arguments: arguments))
                    row.detail = arguments ?? ""
                    row.preview = Self.toolPreview(name, arguments: arguments, title: row.text)
                    row.awaitsResult = true
                    messages.append(row)
                }
            case "toolResult":
                if let toolID = payload?["id"]?.stringValue, let index = toolRows[toolID] {
                    let output = payload?["output"]?.stringValue ?? ""
                    messages[index].detail += "\n\n" + output
                    messages[index].awaitsResult = false
                    if case let .tool(reason, file?, _) = messages[index].preview,
                       payload?["isError"]?.boolValue != true
                    {
                        messages[index].preview = .tool(reason: reason, file: file, change: Self.lineChange(in: output))
                    }
                }
                let files = (try? payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
                if !files.isEmpty {
                    messages.append(ChatMessage(
                        id: id,
                        role: .assistant,
                        text: "",
                        attachments: files.compactMap(attachment),
                    ))
                    unanswered = id
                }
            case "approvalRequested":
                if let approvalID = payload?["approvalID"]?.stringValue {
                    let rowID = Self.rowID(approvalID)
                    approvalIDs[rowID] = approvalID
                    let title = Self.toolTitle(
                        payload?["tool"]?.stringValue ?? "",
                        arguments: payload?["arguments"]?.stringValue,
                    )
                    // what the decision is bound to besides the arguments: why
                    // the gate asked, and a changed description's diff
                    let detail = [
                        payload?["reason"]?.stringValue,
                        payload?["detail"]?["descriptionChanged"]?["diff"]?.stringValue,
                        payload?["arguments"]?.stringValue,
                    ].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    messages.append(ChatMessage(id: rowID, role: .approval(nil), text: title + "\n\n" + detail))
                }
            case "approvalResolved":
                if let approvalID = payload?["approvalID"]?.stringValue,
                   let index = messages.firstIndex(where: { $0.id == Self.rowID(approvalID) })
                {
                    messages[index].role = .approval(payload?["decision"]?.stringValue == "approve" ? .approve : .deny)
                }
            case "error":
                messages.append(ChatMessage(id: id, role: .assistant, text: payload?["message"]?.stringValue ?? ""))
            case "finished":
                finishThinking(at: event.time)
                assistant = nil
                isWorking = false
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    finishThinking(at: event.time)
                    isWorking = false
                }
            default: break
            }
        }
        messages = Self.presentationRows(messages)
        if isWorking {
            if let unanswered, messages.last?.id == unanswered {
                messages.append(ChatMessage(
                    id: Self.firstThoughtID(after: unanswered),
                    role: .thinking(seconds: nil, tools: 0),
                    text: "",
                ))
            }
            Self.keepTrailingSummaryRunning(&messages)
        }
        messages += queued
        for draft in sending where !messages.contains(where: { $0.id == draft.id }) {
            var message = ChatMessage(id: draft.id, role: .user, text: draft.text, attachments: draft.attachments)
            // A running turn takes it at its next step, as the host will say.
            message.isQueued = isWorking
            messages.append(message)
        }
    }

    /// The id of the user message an event shows: a `prompt`, `steer` or
    /// `queued` that carries one.
    static func userMessageID(of event: TaskEvent) -> UUID? {
        guard ["prompt", "steer", "queued"].contains(event.kind) else { return nil }
        return event.payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    /// While the turn runs, its last summary stays unfinished across tool
    /// calls and approvals. Each thought ends when a tool starts, so without
    /// this the title would flip between "Thought for…" and the running one.
    private static func keepTrailingSummaryRunning(_ rows: inout [ChatMessage]) {
        guard let index = rows.lastIndex(where: { !$0.role.needsApproval }),
              case let .thinking(_, tools) = rows[index].role else { return }
        rows[index].role = .thinking(seconds: nil, tools: tools)
        rows[index].preview = latestPreview(in: rows[index].trace)
        rows[index].runningTools = rows[index].trace.count(where: \.awaitsResult)
    }

    /// The newest step with something to show: thinking text, or a call.
    private static func latestPreview(in trace: [ChatMessage]) -> ActivityPreview? {
        for step in trace.reversed() {
            if case .thinking = step.role {
                let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return .thinking(String(text.suffix(ActivityPreview.thinkingTailLength)))
                }
            } else if let preview = step.preview {
                return preview
            }
        }
        return nil
    }

    private static let fileTools: Set<String> = ["write_file", "create_file", "patch_file"]

    /// A call's reason, falling back to its title for a call made without
    /// one (an older session, or a model that left it out).
    private static func toolPreview(_ name: String, arguments: String?, title: String) -> ActivityPreview {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let reason = values?["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let path = values?["path"]?.stringValue ?? ""
        let file = fileTools.contains(name) && !path.isEmpty ? (path as NSString).lastPathComponent : nil
        return .tool(reason: reason.isEmpty ? title : reason, file: file, change: nil)
    }

    /// The `+a -b` the file tools end their first result line with.
    private static func lineChange(in output: String) -> ActivityPreview.LineChange? {
        let firstLine = output.prefix { $0 != "\n" }
        guard firstLine.hasSuffix(")"), let open = firstLine.lastIndex(of: "(") else { return nil }
        let figures = firstLine[firstLine.index(after: open) ..< firstLine.index(before: firstLine.endIndex)]
            .components(separatedBy: ", ").last?.split(separator: " ") ?? []
        guard figures.count == 2, figures[0].hasPrefix("+"), figures[1].hasPrefix("-"),
              let added = Int(figures[0].dropFirst()), let removed = Int(figures[1].dropFirst()) else { return nil }
        return ActivityPreview.LineChange(added: added, removed: removed)
    }

    /// Folds the thoughts, calls and approvals between two replies into one
    /// summary, which counts only the calls in its own trace.
    static func presentationRows(_ messages: [ChatMessage]) -> [ChatMessage] {
        var combined: [ChatMessage] = []
        var summary: Int?
        for (index, message) in messages.enumerated() {
            switch message.role {
            case let .thinking(seconds, _):
                // A finished thought with no text adds only its time: to the
                // summary it follows, or to a new one for the call after it.
                let isEmpty = seconds != nil && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if let summary, case let .thinking(previousSeconds, tools) = combined[summary].role {
                    let totalSeconds = previousSeconds.flatMap { elapsed in seconds.map { elapsed + $0 } }
                    combined[summary].role = .thinking(seconds: totalSeconds, tools: tools)
                    guard !isEmpty else { break }
                    combined[summary].text = [combined[summary].text, message.text].filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    combined[summary].trace.append(message)
                } else {
                    guard !isEmpty || Self.callFollows(messages, index) else { break }
                    summary = combined.count
                    var header = message
                    header.role = .thinking(seconds: seconds, tools: 0)
                    header.trace = isEmpty ? [] : [message]
                    combined.append(header)
                }
            case .tool, .approval:
                if summary == nil {
                    summary = combined.count
                    combined.append(ChatMessage(
                        id: Self.rowID("trace:\(message.id)"),
                        role: .thinking(seconds: 0, tools: 0),
                        text: "",
                    ))
                }
                if let summary {
                    combined[summary].trace.append(message)
                    if case let .thinking(seconds, _) = combined[summary].role {
                        let calls = combined[summary].trace.count(where: { $0.role == .tool })
                        combined[summary].role = .thinking(seconds: seconds, tools: calls)
                    }
                }
                if message.role.needsApproval {
                    combined.append(message)
                }
            case .user, .assistant:
                summary = nil
                combined.append(message)
            }
        }
        return combined.filter {
            if case let .thinking(seconds?, tools) = $0.role {
                return seconds > 0 || tools > 0
            }
            return true
        }
    }

    /// Whether a call or an approval comes right after the row at `index`:
    /// the thought before a call heads the summary that holds it.
    private static func callFollows(_ rows: [ChatMessage], _ index: Int) -> Bool {
        guard rows.indices.contains(index + 1) else { return false }
        let next = rows[index + 1].role
        return next == .tool || next.isApproval
    }

    /// A thought after an unanswered row takes the id its stand-in had.
    private mutating func startThinking(id: UUID, at date: Date) {
        thinking = messages.count
        thinkingStarted = date
        let id = unanswered.map(Self.firstThoughtID) ?? id
        unanswered = nil
        messages.append(ChatMessage(id: id, role: .thinking(seconds: nil, tools: 0), text: ""))
    }

    private static func firstThoughtID(after row: UUID) -> UUID {
        rowID("answer:\(row)")
    }

    private mutating func finishThinking(at date: Date) {
        guard let thinking else { return }
        let seconds = max(0, Int(date.timeIntervalSince(thinkingStarted ?? date)))
        messages[thinking].role = .thinking(seconds: seconds, tools: 0)
        self.thinking = nil
        thinkingStarted = nil
    }

    /// What a message from another conversation says over its bubble.
    static func senderLine(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return String(localized: "From another chat") }
        return String(localized: "From \(title)")
    }

    private static func toolTitle(_ name: String, arguments: String?) -> String {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let path = values?["path"]?.stringValue ?? ""
        switch name {
        case "read_file": return path.isEmpty ? String(localized: "Read a file") : String(localized: "Read \(path)")
        case "write_file", "create_file":
            return path.isEmpty ? String(localized: "Write a file") : String(localized: "Write \(path)")
        case "patch_file": return path.isEmpty ? String(localized: "Edit a file") : String(localized: "Edit \(path)")
        case "list": return String(localized: "List files")
        case "grep", "find": return String(localized: "Search files")
        case "run_code": return String(localized: "Run a command")
        case "build": return String(localized: "Build the project")
        case "install": return String(localized: "Install the package")
        case "remove_package": return String(localized: "Remove the package")
        case "capture_screen": return String(localized: "Capture the screen")
        case "read_ui_tree": return String(localized: "Inspect the screen")
        case "ui_action": return String(localized: "Interact with the screen")
        case "read_logs": return String(localized: "Read logs")
        case "respring": return String(localized: "Restart SpringBoard")
        case "git_status": return String(localized: "Check the repository")
        case "git_diff": return String(localized: "Read the changes")
        case "git_stage": return String(localized: "Stage changes")
        case "git_unstage": return String(localized: "Unstage changes")
        case "git_commit": return String(localized: "Commit changes")
        case "git_fetch": return String(localized: "Fetch from the remote")
        case "git_pull": return String(localized: "Pull from the remote")
        case "git_push": return String(localized: "Push to the remote")
        case "git_clone": return String(localized: "Import the repository")
        case "git_settings": return String(localized: "Read the Git settings")
        case "git_set_author": return String(localized: "Set the commit author")
        case "git_save_credential": return String(localized: "Save a Git credential")
        case "git_remove_credential": return String(localized: "Remove a Git credential")
        case "conversation_create": return String(localized: "Create a chat")
        case "conversation_send": return String(localized: "Send to a chat")
        case "conversation_list": return String(localized: "List chats")
        case "conversation_read": return String(localized: "Read a chat")
        case "conversation_stop": return String(localized: "Stop a chat")
        case "project_template_list": return String(localized: "List project templates")
        case "project_create":
            let project = values?["name"]?.stringValue ?? ""
            return project.isEmpty ? String(localized: "Create a project") : String(localized: "Create \(project)")
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func rowID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        ))
    }
}
