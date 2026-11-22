import ApelinCore
import ApelinProtocol
import Foundation

/// A long conversation's ordinary save adds a few lines instead of rewriting
/// its whole transcript. A rewind, a torn last line and an older build's single
/// JSON file each still open with exactly the events they hold.
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
            payload: .object(["text": .string(text)]),
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
    func seqsOnDisk() async throws -> [UInt64] {
        (try await store.loadEvents(for: id)).map(\.seq.rawValue)
    }
    func expect(_ expected: [UInt64], _ message: String) async throws {
        let actual = try await seqsOnDisk()
        precondition(actual == expected, "\(message): got \(actual), expected \(expected)")
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

    var torn = try Data(contentsOf: transcript)
    torn.append(Data(#"{"seq":3,"text":"cut"#.utf8))
    try torn.write(to: transcript)
    try await expect([1, 2], "A last line cut short must be ignored")

    try await store.save(record(four), revision: 4)
    try await expect([1, 2, 3, 4], "The next save must repair a torn file")

    let summary = try Data(contentsOf: chats.appendingPathComponent(id.uuidString + ".json"))
    let savedRecord = try JSONDecoder().decode(ChatRecord.self, from: summary)
    precondition(savedRecord.eventsOnDisk == 4 && savedRecord.eventsTail != nil,
                 "The summary must carry enough to append on the next save")

    let old = UUID()
    try Data(JSONEncoder().encode([event(1, "old")])).write(
        to: chats.appendingPathComponent(old.uuidString + ".events.json"),
    )
    let migrated = try await store.loadEvents(for: old)
    precondition(migrated.map(\.payload?["text"]?.stringValue) == ["old"],
                 "An older build's single JSON transcript must still open")
}
