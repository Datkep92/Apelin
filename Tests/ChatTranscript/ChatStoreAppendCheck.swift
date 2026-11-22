import ApelinCore
import ApelinProtocol
import Foundation

/// A long conversation's ordinary save adds a few lines instead of rewriting
/// its whole transcript. A rewind, a torn last line, an older build's single
/// JSON file and a summary left behind by an interrupted save each still open
/// with exactly the events they hold, and none duplicates what is on disk.
func checkChatStoreAppend() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-chat-append-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ChatStore(folder: DataFolder(root: root))
    let id = UUID()

    func event(_ seq: UInt64, _ text: String) -> TaskEvent {
        TaskEvent(
            seq: EventSeq(seq),
            kind: "text",
            time: Date(timeIntervalSince1970: Double(seq)),
            payload: .object(["text": .string(text)])
        )
    }
    func record(_ events: [TaskEvent]) -> ChatRecord {
        var record = ChatRecord(summary: ChatSummary(title: "Append", lastInteraction: Date()))
        record.summary.id = id
        record.events = events
        record.eventsLoaded = true
        return record
    }
    let chats = root.appendingPathComponent("Chats", isDirectory: true)
    let transcript = chats.appendingPathComponent(id.uuidString + ".events.jsonl")
    let summaryURL = chats.appendingPathComponent(id.uuidString + ".json")
    func seqsOnDisk() async throws -> [UInt64] {
        (try await store.loadEvents(for: id)).map(\.seq.rawValue)
    }
    func expect(_ expected: [UInt64], _ message: String) async throws {
        let actual = try await seqsOnDisk()
        precondition(actual == expected, "\(message): got \(actual), expected \(expected)")
    }
    func makeSummaryStale(_ onDisk: Int, tail: String?, bytes: Int?) throws {
        var stale = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: summaryURL))
        stale.eventsOnDisk = onDisk
        stale.eventsTail = tail
        stale.eventsBytes = bytes
        try JSONEncoder().encode(stale).write(to: summaryURL)
    }

    let three = [event(1, "one"), event(2, "two"), event(3, "three")]
    try await store.save(record(three), revision: 1)
    let firstSize = try Data(contentsOf: transcript).count
    precondition(firstSize > 0)

    var four = three
    four.append(event(4, "four"))
    try await store.save(record(four), revision: 2)
    let secondSize = try Data(contentsOf: transcript).count
    precondition(secondSize > firstSize && secondSize - firstSize < 1000,
                 "A streamed save must append one line, not rewrite the whole transcript")
    try await expect([1, 2, 3, 4], "An appended line must be read back")

    try await store.save(record(Array(four.prefix(2))), revision: 3)
    try await expect([1, 2], "A rewind must rewrite the whole transcript")
    let atTwo = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: summaryURL))
    let tailAtTwo = atTwo.eventsTail
    let bytesAtTwo = atTwo.eventsBytes
    precondition(tailAtTwo != nil && bytesAtTwo != nil,
                 "A rewind must leave a summary the stale case can imitate")

    var torn = try Data(contentsOf: transcript)
    torn.append(Data(#"{"seq":3,"text":"cut"#.utf8))
    try torn.write(to: transcript)
    try await expect([1, 2], "A last line cut short must be ignored")

    try await store.save(record(four), revision: 4)
    try await expect([1, 2, 3, 4], "The next save must repair a torn file")

    let summary = try Data(contentsOf: summaryURL)
    let savedRecord = try JSONDecoder().decode(ChatRecord.self, from: summary)
    precondition(savedRecord.eventsOnDisk == 4 && savedRecord.eventsTail != nil,
                 "The summary must carry enough to append on the next save")

    // An interrupted save can leave a summary describing two events while the
    // file already holds four. Appending from the old count is the duplication
    // this guards against.
    var five = four
    five.append(event(5, "five"))
    var staleFive = record(five)
    staleFive.eventsOnDisk = 2
    staleFive.eventsTail = tailAtTwo
    staleFive.eventsBytes = bytesAtTwo
    try makeSummaryStale(2, tail: tailAtTwo, bytes: bytesAtTwo)
    try await store.save(staleFive, revision: 5)
    try await expect([1, 2, 3, 4, 5], "A stale summary must not append events the file already holds")

    // The other side of the same fault: a record that is shorter than the file
    // must never rewrite the file and lose its later events.
    var staleThree = record(Array(five.prefix(3)))
    staleThree.eventsOnDisk = 2
    staleThree.eventsTail = tailAtTwo
    staleThree.eventsBytes = bytesAtTwo
    try makeSummaryStale(2, tail: tailAtTwo, bytes: bytesAtTwo)
    try await store.save(staleThree, revision: 6)
    try await expect([1, 2, 3, 4, 5], "A shorter in-memory record must not overwrite a longer transcript")

    let old = UUID()
    try Data(JSONEncoder().encode([event(1, "old")])).write(
        to: chats.appendingPathComponent(old.uuidString + ".events.json")
    )
    let migrated = try await store.loadEvents(for: old)
    precondition(migrated.map(\.payload?["text"]?.stringValue) == ["old"],
                 "An older build's single JSON transcript must still open")
}
