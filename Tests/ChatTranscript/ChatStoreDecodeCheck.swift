import ApelinCore
import ApelinProtocol
import Foundation

/// One conversation this build cannot read costs that conversation, never the
/// list: a retry state saved before `triedKeys` existed, a failure kind or a
/// reasoning effort this build cannot name, and a file with no summary at all
/// are each read for what they hold, and the file that holds no conversation
/// stays on disk untouched (`ChatStore.load`).
func checkChatStoreDecode() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-chat-decode-\(UUID())")
    let chats = root.appendingPathComponent("Chats", isDirectory: true)
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func file(_ id: UUID) -> URL {
        chats.appendingPathComponent(id.uuidString + ".json")
    }

    func summary(_ id: UUID, _ title: String) -> String {
        """
        "summary":{"id":"\(id.uuidString)","title":"\(title)","updated":816069038,\
        "isPinned":false,"isWorking":false}
        """
    }

    /// A conversation as an older build left it: its retry state was written
    /// before `triedKeys` existed, one candidate's effort list names an effort
    /// this build no longer offers, the next candidate carries a saved
    /// configuration, and the failure kind is a name this build does not know.
    let older = UUID()
    try Data("""
        {\(summary(older, "Older retry")),\
        "retryState":{"remaining":[\
        {"provider":"openAICompatible","model":"kilo-auto/free","supportedEfforts":["low","ultra"]},\
        {"provider":"openAICompatible","model":"kilo-auto/paid","profileID":"cfg-2"}],\
        "text":"carry on","attempts":2,"kind":"allowanceSpent",\
        "cooldowns":{"openAICompatible||kilo-auto/free":816069338.2}}}
        """.utf8).write(to: file(older))

    /// A file whose summary has no id: no conversation to list.
    let headless = UUID()
    try Data(#"{"summary":{"title":"no id","updated":816069038,"isPinned":false,"isWorking":false}}"#.utf8)
        .write(to: file(headless))

    /// A retry state this build wrote: the walk's own list kept beside what is
    /// left of it, and a wait for a run to end that the reader's own tap is
    /// waiting through.
    let modern = UUID()
    try Data("""
        {\(summary(modern, "Modern retry")),\
        "retryState":{"remaining":[],"ordered":[\
        {"provider":"openAICompatible","model":"kilo-auto/paid","profileID":"cfg-1"}],\
        "triedKeys":["openAICompatible|cfg-1|kilo-auto/paid"],"text":"carry on","attempts":3,\
        "awaitingTurn":true,"askedByReader":true,"kind":"refusedKey"}}
        """.utf8).write(to: file(modern))

    /// One this build reads whole.
    let plain = UUID()
    try Data("{\(summary(plain, "Plain"))}".utf8).write(to: file(plain))

    let records = try await ChatStore(folder: DataFolder(root: root)).load()
    precondition(
        records.count == 3,
        "one file that is no conversation costs only itself: \(records.map(\.summary.title))",
    )
    precondition(records.contains { $0.summary.id == plain }, "the conversation beside them still loads")
    precondition(FileManager.default.fileExists(atPath: file(headless).path), "and the file left out stays on disk")

    guard let retry = records.first(where: { $0.summary.id == older })?.retryState else {
        preconditionFailure("a retry state written before triedKeys existed still reads")
    }
    precondition(retry.triedKeys.isEmpty, "it reads with no key tried yet")
    precondition(retry.text == "carry on" && retry.attempts == 2, "and keeps what it does hold")
    precondition(retry.kind == nil, "a failure kind this build cannot name costs the kind alone")
    precondition(retry.remaining.count == 2, "both candidates still read: \(retry.remaining.map(\.model))")
    precondition(
        retry.remaining[0].supportedEfforts.isEmpty,
        "an effort this build cannot name costs that snapshot, not the model",
    )
    precondition(retry.remaining[1].profileID == "cfg-2", "a saved configuration keeps its id")
    precondition(retry.cooldowns?.count == 1, "and the cooldowns read")
    precondition(retry.ordered == nil && retry.askedByReader == nil, "a field a later build added costs nothing")

    guard let kept = records.first(where: { $0.summary.id == modern })?.retryState else {
        preconditionFailure("a retry state this build wrote reads whole")
    }
    precondition(kept.ordered?.count == 1, "the walk's own list is kept")
    precondition(kept.awaitingTurn == true, "so is a wait for the run to end")
    precondition(kept.askedByReader == true, "and that the reader's own tap is what waits")
    precondition(kept.triedKeys.count == 1 && kept.attempts == 3, "with the keys that failed and the tries spent")
    precondition(
        kept.canAskAgain(from: kept.ordered?.first),
        "so a walk with nothing left still has its list to go round",
    )
    print("ok: a conversation this build cannot read whole is left on disk, and the others still load")
}