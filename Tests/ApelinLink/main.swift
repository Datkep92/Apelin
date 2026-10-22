import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

func link(_ text: String) -> ApelinLink? {
    URL(string: text).flatMap(ApelinLink.init(url:))
}

// MARK: - Parsing

let session = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
require(link("apelin://conversation/\(session)") == .conversation(session), "A conversation by its session ID")
require(link("APELIN://Conversation/\(session)/") == .conversation(session), "Scheme and kind ignore case; a trailing slash is fine")
require(link("apelin:conversation/\(session)") == .conversation(session), "The kind may be the first path component")
require(link("apelin://conversation/\(session)?from=widget#top") == .conversation(session), "Query and fragment are ignored")
require(link("apelin://project/I3%20Chain%20Tweak") == .project("I3 Chain Tweak"), "A folder name is percent-decoded")
require(link("apelin://project/\(session)") == .project(session), "A project by its projectID")
require(link("apelin://") == .app, "The bare scheme opens the app")
require(link("apelin:") == .app, "So does the scheme alone")
for unknown in [
    "apelin://conversation", "apelin://conversation/", "apelin://project",
    "apelin://conversation/a/b", "apelin://settings/x", "apelin://chat/\(session)",
    "apelin://conversation/..", "apelin://project/.", "apelin://conversation/a%00b",
    "apelin://conversation/a%2Fb", "apelin://project/" + String(repeating: "x", count: 256),
] {
    require(link(unknown) == .unknown, "Unknown or malformed: \(unknown)")
}

for other in ["https://example.com/conversation/x", "file:///tmp/a.apeproj", "ighostvt://new"] {
    require(link(other) == nil, "Not an apelin link: \(other)")
}

// MARK: - Building, and reading back what was built

require(ApelinLink.conversation(session).url.absoluteString == "apelin://conversation/\(session)", "The documented form")
require(ApelinLink.project("I3 Chain Tweak").url.absoluteString == "apelin://project/I3%20Chain%20Tweak", "Spaces escaped")
require(ApelinLink.app.url.absoluteString == "apelin://", "The app")
for name in ["I3 Chain Tweak", "相机翻译", "a?b#c;d", "100% done", session] {
    for built in [ApelinLink.conversation(name), .project(name)] {
        require(ApelinLink(url: built.url) == built, "Round trip: \(name)")
    }
}

// MARK: - The snapshot's order and counts

typealias Chat = ChatWidgetSnapshot.Chat
let now = Date()
func chat(_ id: String, _ status: Chat.Status, _ age: TimeInterval) -> (chat: Chat, updated: Date) {
    (Chat(id: id, title: id, project: nil, status: status, approvalTool: status == .waiting ? "install" : nil),
     now.addingTimeInterval(-age))
}

let snapshot = ChatWidgetSnapshot(chats: [
    chat("old-done", .done, 500),
    chat("working-old", .working, 300),
    chat("failed", .failed, 10),
    chat("waiting", .waiting, 400),
    chat("working-new", .working, 20),
    chat("new-done", .done, 1),
])
require(snapshot.chats.map(\.id) == ["waiting", "working-new", "working-old", "new-done", "failed", "old-done"],
        "Waiting first, then working, then the rest, newest first within each")
require(snapshot.totalCount == 6 && snapshot.workingCount == 2 && snapshot.waitingCount == 1, "Counts cover every chat")
require(snapshot.mostUrgent?.id == "waiting", "The one waiting most needs a look")

let activity = snapshot.inProgress
require(activity.chats.map(\.id) == ["waiting", "working-new", "working-old"], "The activity lists only chats in progress")
require(activity.totalCount == 3, "Its count is of chats in progress")
require(ChatWidgetSnapshot(chats: [chat("a", .done, 1)]).inProgress.totalCount == 0, "Nothing in progress, no activity")
require(ChatWidgetSnapshot(chats: [chat("w", .working, 9), chat("v", .working, 1)]).inProgress.mostUrgent?.id == "v",
        "With nothing waiting, the latest working")

let many = ChatWidgetSnapshot(chats: (0 ..< 20).map { chat("c\($0)", .done, TimeInterval($0)) })
require(many.chats.count == ChatWidgetSnapshot.listLimit && many.totalCount == 20, "The list is capped, the count is not")
let busy = ChatWidgetSnapshot(chats: (0 ..< 9).map { chat("w\($0)", .working, TimeInterval($0)) }).inProgress
require(busy.chats.count == ChatWidgetSnapshot.activityLimit && busy.totalCount == 9, "The activity's payload is capped")
let encoded = try JSONEncoder().encode(busy)
require(encoded.count < 4096, "The activity's payload stays within ActivityKit's 4 KB")
try require(JSONDecoder().decode(ChatWidgetSnapshot.self, from: encoded) == busy, "The snapshot round-trips")

print("ok: ApelinLink and ChatWidgetSnapshot")
