import ApelinCore
import ApelinProtocol
import Foundation

func event(_ seq: UInt64, _ kind: String, _ values: [String: JSONValue] = [:]) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: kind, time: Date(timeIntervalSince1970: Double(seq)), payload: .object(values))
}

let userID = UUID()
let events = [
    event(1, "prompt", ["id": .string(userID.uuidString), "text": .string("Make a change")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("A supplied reasoning summary")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("read_file"), "arguments": .string("{\"path\":\"README.md\"}")]),
    event(5, "toolResult", ["id": .string("t1"), "output": .string("file content")]),
    event(6, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("run_code"), "arguments": .string("{}")]),
    event(7, "approvalResolved", ["approvalID": .string("a1"), "decision": .string("deny")]),
    event(8, "messageStarted"), event(9, "text", ["text": .string("Partial")]),
    event(10, "message", ["text": .string("Final text")]), event(11, "finished"),
]
let transcript = ChatTranscript(events: events) { _ in nil }
precondition(!transcript.isWorking)
precondition(transcript.messages.first?.id == userID)
precondition(transcript.messages.filter { $0.role == .assistant }.map(\.text) == ["Final text"])
precondition(!transcript.messages.contains { $0.role == .tool })
precondition(!transcript.messages.contains { $0.role.isApproval })
precondition(transcript.messages.flatMap(\.trace).first { $0.role.isApproval }?.role == .approval(.deny))
precondition(transcript.messages.contains { $0.role == .thinking(seconds: 3, tools: 1) })
precondition(transcript.messages.map(\.id) == ChatTranscript(events: events) { _ in nil }.messages.map(\.id))
precondition(ChatTranscript(events: Array(events.prefix(6))) { _ in nil }.messages.contains { $0.role.needsApproval })
precondition(ChatTranscript(events: Array(events.prefix(9))) { _ in nil }.isWorking)
let toolLoop = [
    event(1, "messageStarted"), event(2, "thinking", ["text": .string("First thought")]),
    event(3, "toolCall", ["id": .string("t1"), "tool": .string("list")]),
    event(4, "toolResult", ["id": .string("t1")]), event(4, "message", ["text": .string("")]),
    event(5, "messageStarted"), event(6, "thinking", ["text": .string("Second thought")]),
    event(7, "toolCall", ["id": .string("t2"), "tool": .string("read_file")]),
    event(8, "messageStarted"), event(9, "message", ["text": .string("Answer")]), event(10, "finished"),
]
let combined = ChatTranscript(events: toolLoop) { _ in nil }.messages
precondition(combined.count == 2)
precondition(combined[0].role == .thinking(seconds: 5, tools: 2))
precondition(combined[0].text == "First thought\n\nSecond thought")
precondition(combined[0].trace.filter { $0.role == .tool }.count == 2)
precondition(combined[0].trace.first { $0.role == .tool }?.detail != nil)
precondition(combined[1].role == .assistant && combined[1].text == "Answer")
print("ok: chat replay, streaming replacement, hidden tools, alternating thought summaries, approval decisions and stable identities")

let noThought = ChatTranscript(events: [event(1, "messageStarted"), event(2, "message", ["text": .string("Answer")]), event(3, "finished")]) { _ in nil }
precondition(noThought.messages.count == 1 && noThought.messages[0].role == .assistant, "An empty model start is not a completed thought")
let fastThought = ChatTranscript(events: [
    TaskEvent(seq: EventSeq(1), kind: "messageStarted", time: Date(timeIntervalSince1970: 1)),
    TaskEvent(seq: EventSeq(2), kind: "thinking", time: Date(timeIntervalSince1970: 1.1), payload: .object(["text": .string("Reasoning")])),
    TaskEvent(seq: EventSeq(3), kind: "message", time: Date(timeIntervalSince1970: 1.2), payload: .object(["text": .string("Answer")])),
    event(4, "finished"),
]) { _ in nil }
precondition(fastThought.messages.count == 1 && fastThought.messages[0].role == .assistant, "Zero-second, zero-tool summaries are hidden")
precondition(!fastThought.isWorking)
let orphanTool = ChatTranscript(events: [event(1, "toolCall", ["id": .string("tool"), "tool": .string("list")]), event(2, "finished")]) { _ in nil }
precondition(orphanTool.messages[0].role == .thinking(seconds: 0, tools: 1), "A tool without supplied thinking still counts once")
print("ok: empty thoughts, subsecond reasoning, standalone tools and ended turns")

/// The approval card shows what the decision is bound to: why the gate
/// asked, a changed description's diff, then the arguments.
let installApproval = ChatTranscript(events: [
    event(1, "prompt", ["text": .string("Install it")]),
    event(2, "approvalRequested", [
        "approvalID": .string("a2"), "tool": .string("install"), "arguments": .string("{\"artifact_id\":\"x\"}"),
        "reason": .string("the packaging description changed since the template or the last approval"),
        "detail": .object(["descriptionChanged": .object([
            "kind": .string("packaging"), "digest": .string("d"), "diff": .string("+postinst"),
        ])]),
    ]),
]) { _ in nil }.messages.first { $0.role.needsApproval }
precondition(installApproval?.approvalTitle == "Install the package")
let approvalDetail = installApproval?.approvalDetail ?? ""
let detailPositions = ["the packaging description changed", "+postinst", "{\"artifact_id\":\"x\"}"]
    .compactMap { approvalDetail.range(of: $0)?.lowerBound }
precondition(
    detailPositions.count == 3 && detailPositions == detailPositions.sorted(),
    "the card names the reason, the diff, then the arguments: \(approvalDetail)",
)
print("ok: an approval card carries the reason and the description diff before the arguments")

let storageURL = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-chat-store-\(UUID())")
try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: storageURL) }
let storage = ChatStore(folder: DataFolder(root: storageURL))
let record = ChatRecord(summary: ChatSummary(title: "Deletion regression", updated: Date()))
try await storage.save(record, revision: 1)
let savedRecords = try await storage.load()
precondition(savedRecords.count == 1, "A chat saved through the temporary-directory alias must load")
try await storage.remove(record.summary.id)
try await storage.save(record, revision: 2)
let deletedRecords = try await storage.load()
precondition(deletedRecords.isEmpty, "A queued save must not resurrect a deleted chat")
let unsaved = ChatRecord(summary: ChatSummary(title: "Unsaved", updated: Date()))
try await storage.remove(unsaved.summary.id)
try await storage.save(unsaved, revision: 3)
let unsavedRecords = try await storage.load()
precondition(unsavedRecords.isEmpty, "Deleting before the first save must also prevent resurrection")
let retryURL = storageURL.appendingPathComponent("retry")
try FileManager.default.createDirectory(at: retryURL, withIntermediateDirectories: false)
let obstruction = retryURL.appendingPathComponent("Chats")
try Data().write(to: obstruction)
let retryStore = ChatStore(folder: DataFolder(root: retryURL))
do {
    try await retryStore.save(record, revision: 1)
    preconditionFailure("Saving through a file must fail")
} catch {}
try FileManager.default.removeItem(at: obstruction)
try await retryStore.save(record, revision: 1)
let retriedRecords = try await retryStore.load()
precondition(retriedRecords.count == 1, "A failed save must allow retrying the same revision")
print("ok: chat deletion before/after saving, queued-save suppression and failed-save retry")

func activityTitle(_ seconds: Int?, _ tools: Int) -> String {
    ChatMessage(role: .thinking(seconds: seconds, tools: tools), text: "").activityTitle
}

precondition(activityTitle(0, 0).isEmpty)
precondition(activityTitle(0, 1) == "Called 1 tool")
precondition(activityTitle(0, 3) == "Called 3 tools")
precondition(activityTitle(2, 0) == "Thought for 2 seconds")
precondition(activityTitle(1, 2) == "Thought for 1 second and called 2 tools")
precondition(activityTitle(nil, 0) == "Thinking…")
print("ok: activity summary shows only positive duration and tool counts")

/// While the turn runs, the trailing summary stays unfinished across tool
/// calls and previews the newest step: the call's reason, a file edit's name
/// and its line counts once the result is in, then newer thinking text.
let running = [
    event(1, "prompt", ["text": .string("Change the hook")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Look at the hook")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("patch_file"),
                          "arguments": .string("{\"reason\":\"Turn the hook on\",\"path\":\"Sources/Tweak.x\"}")]),
]
let calling = ChatTranscript(events: running) { _ in nil }.messages.last
precondition(calling?.role == .thinking(seconds: nil, tools: 1))
precondition(calling?.preview == .tool(reason: "Turn the hook on", file: "Tweak.x", change: nil))
let patched = running + [event(5, "toolResult", ["id": .string("t1"), "output": .string("Patched Sources/Tweak.x (1 replacement, +3 -1)\n--- a/Sources/Tweak.x")])]
precondition(ChatTranscript(events: patched) { _ in nil }.messages.last?.preview
    == .tool(reason: "Turn the hook on", file: "Tweak.x", change: .init(added: 3, removed: 1)))
let thinkingAgain = patched + [event(6, "messageStarted"), event(7, "thinking", ["text": .string("Now build it")])]
precondition(ChatTranscript(events: thinkingAgain) { _ in nil }.messages.last?.preview == .thinking("Now build it"))
let unnamed = [event(1, "messageStarted"), event(2, "toolCall", ["id": .string("t1"), "tool": .string("build"), "arguments": .string("{}")])]
precondition(ChatTranscript(events: unnamed) { _ in nil }.messages.last?.preview == .tool(reason: "Build the project", file: nil, change: nil))
let ended = ChatTranscript(events: patched + [event(6, "finished")]) { _ in nil }.messages.last
precondition(ended?.role.isThinking == false && ended?.preview == nil)
print("ok: a running summary stays running across calls and previews its newest step")

/// Whether every summary, and every step in its trace, counts only the calls
/// in its own trace.
func countsOwnCalls(_ rows: [ChatMessage]) -> Bool {
    rows.allSatisfy { row in
        guard case let .thinking(_, tools) = row.role else { return true }
        return tools == row.trace.count(where: { $0.role == .tool }) && countsOwnCalls(row.trace)
    }
}

/// One model message's text is one row. The relay flushes the streamed text
/// before the call it starts writing, and the full text follows at the
/// message's end; the summary the call starts holds that call.
let textBeforeCall = [
    event(1, "prompt", ["text": .string("Build it")]),
    event(2, "messageStarted"), event(3, "text", ["text": .string("I'll build the release")]),
    event(4, "toolCallPreparing"),
    event(5, "message", ["text": .string("I'll build the release, install it and open it.")]),
    event(6, "toolCall", ["id": .string("t1"), "tool": .string("build"), "arguments": .string("{}")]),
]
let building = ChatTranscript(events: textBeforeCall) { _ in nil }.messages
precondition(building.filter { $0.role == .assistant }.map(\.text) == ["I'll build the release, install it and open it."], "One message's text is one row")
precondition(building.count == 3, "The prompt, the reply and the running call")
precondition(building.last?.role == .thinking(seconds: nil, tools: 1) && building.last?.runningTools == 1)
precondition(countsOwnCalls(building), "No summary counts a call outside its trace")
let built = ChatTranscript(events: textBeforeCall + [
    event(7, "toolResult", ["id": .string("t1"), "output": .string("Built")]),
    event(8, "messageStarted"), event(9, "message", ["text": .string("Done.")]), event(10, "finished"),
]) { _ in nil }.messages
precondition(built.filter { $0.role == .assistant }.map(\.text) == ["I'll build the release, install it and open it.", "Done."])
precondition(built.map(\.role) == [.user, .assistant, .thinking(seconds: 2, tools: 1), .assistant])
precondition(countsOwnCalls(built))
print("ok: a message's text before its call is one row, and the call is in the summary after it")

/// Summaries separated by a reply count their own calls, not the turn's.
let twoSummaries = [
    event(1, "prompt", ["text": .string("Turn the hook on and build")]),
    event(2, "messageStarted"), event(3, "thinking", ["text": .string("Read the hook first")]),
    event(4, "toolCall", ["id": .string("t1"), "tool": .string("read_file"), "arguments": .string("{\"path\":\"Tweak.x\"}")]),
    event(5, "toolResult", ["id": .string("t1"), "output": .string("%hook")]),
    event(6, "messageStarted"), event(7, "text", ["text": .string("The hook is off.")]), event(8, "toolCallPreparing"),
    event(9, "message", ["text": .string("The hook is off. Turning it on.")]),
    event(10, "toolCall", ["id": .string("t2"), "tool": .string("patch_file"), "arguments": .string("{\"path\":\"Tweak.x\"}")]),
    event(11, "toolResult", ["id": .string("t2"), "output": .string("Patched Tweak.x (1 replacement, +1 -1)")]),
    event(12, "messageStarted"), event(13, "toolCallPreparing"), event(14, "message", ["text": .string("")]),
    event(15, "toolCall", ["id": .string("t3"), "tool": .string("build"), "arguments": .string("{}")]),
    event(16, "toolResult", ["id": .string("t3"), "output": .string("Built")]),
    event(17, "messageStarted"), event(18, "message", ["text": .string("Built.")]), event(19, "finished"),
]
let summaries = ChatTranscript(events: twoSummaries) { _ in nil }.messages
precondition(summaries.map(\.role) == [.user, .thinking(seconds: 3, tools: 1), .assistant, .thinking(seconds: 4, tools: 2), .assistant], "Each summary counts its own calls")
precondition(summaries[2].text == "The hook is off. Turning it on.")
precondition(countsOwnCalls(summaries))
let stillBuilding = ChatTranscript(events: Array(twoSummaries.prefix(15))) { _ in nil }.messages.last
precondition(stillBuilding?.role == .thinking(seconds: nil, tools: 2) && stillBuilding?.runningTools == 1)
precondition(stillBuilding?.activityTitle == "Executing 1 tool…")
print("ok: each summary counts only the calls in its own trace")

/// A message another conversation's agent sent names that conversation over
/// its bubble; the user's own has no such line.
let fromEvents = [
    event(1, "prompt", ["text": .string("Review Tweak.x"), "from": .string("opener-session")]),
    event(2, "prompt", ["text": .string("My own words")]),
    event(3, "prompt", ["text": .string("Unknown sender"), "from": .string("gone-session")]),
]
let fromTranscript = ChatTranscript(events: fromEvents, conversationTitle: { $0 == "opener-session" ? "Plan the tweak" : nil }) { _ in nil }
let users = fromTranscript.messages.filter { $0.role == .user }
precondition(users.map(\.sender) == ["From Plan the tweak", nil, "From another chat"])
precondition(ChatTranscript(events: fromEvents) { _ in nil }.messages.first?.sender == "From another chat")
print("ok: messages from other conversations name their sender")

// conversationOpened on an opener's task adopts the conversation into the
// opener's project, once; agentList adopts what the app missed.
let openerSession = UUID().uuidString.lowercased()
let childSession = UUID().uuidString.lowercased()
let opener = ChatRecord(summary: ChatSummary(title: "Plan", updated: Date(), projectName: "Clock"), sessionID: openerSession, task: TaskHandle(taskID: TaskID("opener-task"), kind: .agent))
let opened: JSONValue = .object([
    "sessionID": .string(childSession),
    "task": .object(["taskID": .string("child-task"), "kind": .string("agent")]),
    "title": .string("Docs"),
    "prompt": .string("Write the README\nand the changelog"),
])
let adopted = ChatAdoption.record(opened: opened, parent: opener, records: [opener], now: Date(timeIntervalSince1970: 7))
precondition(adopted?.sessionID == childSession && adopted?.task == TaskHandle(taskID: TaskID("child-task"), kind: .agent))
precondition(adopted?.summary.projectName == "Clock" && adopted?.summary.title == "Docs" && adopted?.summary.isWorking == true)
precondition(adopted?.summary.updated == Date(timeIntervalSince1970: 7) && adopted?.events.isEmpty == true)
precondition(ChatAdoption.record(opened: opened, parent: opener, records: [opener, adopted!]) == nil, "a conversation is adopted once")
var untitled = opened
if case var .object(fields) = untitled {
    fields["title"] = nil
    untitled = .object(fields)
}

precondition(ChatAdoption.record(opened: untitled, parent: opener, records: [opener])?.summary.title == "Write the README")
precondition(ChatAdoption.record(opened: .object(["sessionID": .string("not-a-uuid")]), parent: opener, records: [opener]) == nil)
let general = ChatRecord(summary: ChatSummary(title: "General", updated: Date(), projectName: nil), sessionID: openerSession)
precondition(ChatAdoption.record(opened: opened, parent: general, records: [general]) == nil, "General Chat adopts nothing")
precondition(ChatAdoption.title(" ", prompt: nil) == "New Chat")

func listed(_ state: TaskState, parent: String?) -> AgentSessionSummary {
    AgentSessionSummary(sessionID: childSession, task: TaskHandle(taskID: TaskID("child-task"), kind: .agent), title: "Docs", state: state, updatedAt: Date(timeIntervalSince1970: 9), parentSessionID: parent)
}

let missed = ChatAdoption.record(session: listed(.running, parent: openerSession), records: [opener])
precondition(missed?.summary.projectName == "Clock" && missed?.summary.title == "Docs" && missed?.sessionID == childSession)
precondition(ChatAdoption.record(session: listed(.running, parent: openerSession), records: [opener, missed!]) == nil)
precondition(ChatAdoption.record(session: listed(.succeeded, parent: openerSession), records: [opener]) == nil, "an ended one is not adopted")
precondition(ChatAdoption.record(session: listed(.running, parent: nil), records: [opener]) == nil, "the app's own are not adopted")
precondition(ChatAdoption.record(session: listed(.running, parent: "unknown"), records: [opener]) == nil, "nor one whose opener has no record")
print("ok: conversations agents open are adopted once, into the opener's project")

// A sent message shows at once under its draft's id; the host's `prompt` or
// `queued` event with that id takes its place, one row each time.
let file = ComposerAttachment(name: "notes.md", data: Data("notes".utf8), text: "notes")
let sent = ComposerDraft(text: "Build it", attachments: [file])
let local = ChatTranscript(events: [], sending: [sent]) { _ in nil }
precondition(local.messages.map(\.id) == [sent.id] && local.messages[0].role == .user)
precondition(local.messages[0].text == "Build it" && local.messages[0].attachments == [file])
precondition(!local.messages[0].isQueued && !local.isWorking, "a local row does not start a turn")
let echoed = ChatTranscript(events: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])], sending: [sent]) { _ in nil }
precondition(echoed.messages.filter { $0.id == sent.id }.count == 1 && echoed.messages[0].id == sent.id)
precondition(echoed.isWorking && echoed.messages.last?.role == .thinking(seconds: nil, tools: 0))
let busy = [event(1, "prompt", ["text": .string("Earlier")]), event(2, "messageStarted")]
let waiting = ChatTranscript(events: busy, sending: [sent]) { _ in nil }
precondition(waiting.messages.last?.id == sent.id && waiting.messages.last?.isQueued == true, "a running turn will queue it")
let queuedEcho = busy + [event(3, "queued", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
let hostQueued = ChatTranscript(events: queuedEcho, sending: [sent]) { _ in nil }
precondition(hostQueued.messages.filter { $0.id == sent.id }.count == 1)
precondition(hostQueued.messages.last?.id == sent.id && hostQueued.messages.last?.isQueued == true)
print("ok: a sent message shows at once and its prompt or queued echo replaces it")

var sendingRecord = ChatRecord(summary: ChatSummary(title: "Send", updated: Date()))
let second = ComposerDraft(text: "And test it")
sendingRecord.sending = [sent, second]
let taken = sendingRecord.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])])
precondition(taken.map(\.draft.id) == [sent.id] && sendingRecord.sending?.map(\.id) == [second.id])
_ = sendingRecord.takeEchoed(by: [event(2, "queued", ["id": .string(second.id.uuidString), "text": .string("And test it")])])
precondition(sendingRecord.sending == nil)

var failed = ChatRecord(summary: ChatSummary(title: "Failed", updated: Date()))
failed.sending = [sent]
precondition(failed.takeBack(sent) && failed.sending == nil, "a failed send leaves no row")
precondition(failed.draft.id == sent.id && failed.draft.text == "Build it" && failed.draft.attachments == [file])
precondition(ChatTranscript(events: failed.events, sending: failed.sending ?? []) { _ in nil }.messages.isEmpty)
var typedSince = ChatRecord(summary: ChatSummary(title: "Typed", updated: Date()))
typedSince.sending = [sent]
typedSince.draft = ComposerDraft(text: "Next")
precondition(!typedSince.takeBack(sent) && typedSince.draft.text == "Next" && typedSince.sending == nil, "what was typed since stays")
var recordedFirst = ChatRecord(summary: ChatSummary(title: "Recorded", updated: Date()))
recordedFirst.sending = [sent]
recordedFirst.events = [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
precondition(!recordedFirst.takeBack(sent) && recordedFirst.draft.text.isEmpty, "a message the host recorded is not put back")
print("ok: an echo settles its message and a failed send takes it back into an empty draft")

var killed = ChatRecord(summary: ChatSummary(title: "Killed", updated: Date()))
killed.sending = [sent]
killed.reclaimUnsent()
precondition(killed.sending == nil && killed.draft.id == sent.id && killed.draft.attachments == [file], "an unechoed message returns to the draft")
precondition(killed.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]).isEmpty)
precondition(killed.draft.text.isEmpty, "a returned draft the host did take empties on its echo")
var edited = ChatRecord(summary: ChatSummary(title: "Edited", updated: Date()))
edited.sending = [sent]
edited.reclaimUnsent()
edited.draft.text = "Build it twice"
_ = edited.takeEchoed(by: [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])])
precondition(edited.draft.text == "Build it twice", "an edited draft stays")
var merged = ChatRecord(summary: ChatSummary(title: "Merged", updated: Date()))
merged.sending = [sent]
merged.draft = ComposerDraft(text: "Typed after")
merged.reclaimUnsent()
precondition(merged.draft.text == "Build it\n\nTyped after" && merged.draft.attachments == [file])
var settled = ChatRecord(summary: ChatSummary(title: "Settled", updated: Date()))
settled.sending = [sent]
settled.events = [event(1, "prompt", ["id": .string(sent.id.uuidString), "text": .string("Build it")])]
settled.reclaimUnsent()
precondition(settled.sending == nil && settled.draft.text.isEmpty, "an echoed message is not put back")
let stored = try JSONEncoder().encode(killed)
precondition(!String(decoding: stored, as: UTF8.self).contains("\"sending\""))
let reread = try JSONDecoder().decode(ChatRecord.self, from: stored)
precondition(reread.sending == nil && reread.draft.text.isEmpty, "a file without `sending` reads")
var pendingRecord = killed
pendingRecord.sending = [sent]
let pendingCopy = try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(pendingRecord))
precondition(pendingCopy.sending?.first?.attachments == [file], "a message being sent keeps its attachment bytes on disk")
print("ok: a relaunch puts unechoed messages back in the draft, and older files still read")

// A turn starts with a user message a run has taken, or one just sent to an
// idle conversation; a message waiting for a running turn starts none yet.
precondition(TurnFollowing.turnMessage(in: local.messages) == sent.id, "a message sent to an idle conversation starts a turn")
precondition(TurnFollowing.turnMessage(in: waiting.messages) != sent.id, "one a running turn will take starts none yet")
precondition(TurnFollowing.turnMessage(in: hostQueued.messages) == waiting.messages.first?.id)
precondition(TurnFollowing.turnMessage(in: fromTranscript.messages) == fromTranscript.messages.last { $0.role == .user }?.id,
             "a message from another conversation starts a turn")
precondition(TurnFollowing.turnMessage(in: []) == nil)

/// Following a turn moves toward the newest content until the turn's message
/// reaches the top of the visible area, then no further, and never back up.
func follow(_ offset: CGFloat, latest: CGFloat, top: CGFloat) -> (offset: CGFloat, reachesTop: Bool) {
    TurnFollowing.step(offset: offset, latest: latest, messageTop: top, topInset: 100)
}

precondition(follow(0, latest: 300, top: 500) == (300, false), "within a page it shows the newest content")
precondition(follow(300, latest: 450, top: 500) == (400, true), "past a page it stops with the message at the top")
precondition(follow(300, latest: 400, top: 500) == (400, true), "exactly a page is the last step")
precondition(follow(600, latest: 900, top: 500) == (600, true), "a message already above is not scrolled back to")
precondition(follow(300, latest: 300, top: 900) == (300, false), "nothing new leaves the list where it is")
print("ok: a turn is followed for at most a page, from its message")
