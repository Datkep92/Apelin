import ApelinCore
import ApelinProtocol
import Foundation

/// Reading the words: what a conversation said is searched, what a tool did is
/// not, case and accents are set aside, and the line a match sits in comes back
/// cut and marked.
func checkChatContentSearch() {
    func event(_ seq: UInt64, _ kind: String, _ values: [String: JSONValue] = [:]) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: kind, time: Date(timeIntervalSince1970: Double(seq)), payload: .object(values))
    }

    let conversation = [
        event(1, "prompt", ["text": .string("Make the sidebar search find what was said")]),
        event(2, "toolCall", ["tool": .string("file_read"), "arguments": .string("{\"path\":\"Buổi họp.md\"}")]),
        event(3, "toolResult", ["output": .string("a hundred lines about buoi hop")]),
        event(4, "thinking", ["text": .string("Đọc lại phần tìm kiếm trước")]),
        event(5, "message", ["text": .string("First line\nand left the rest alone")]),
        event(6, "compactionFinished", ["summary": .string("Kept: the sidebar search")]),
        event(7, "finished"),
    ]

    // what was said, whatever its case
    precondition(ChatContentSearch.hit("SIDEBAR", in: conversation)?.line == "Make the sidebar search find what was said")
    // and whatever its accents: the reader types buoi, the word says Buổi
    precondition(ChatContentSearch.hit("doc lai phan tim kiem", in: conversation)?.line == "Đọc lại phần tìm kiếm trước")
    // the line answered is the one the words are in, not the whole message
    precondition(ChatContentSearch.hit("rest alone", in: conversation)?.line == "and left the rest alone")
    // what an agent thought, and what a compaction kept, are searched too
    precondition(ChatContentSearch.hit("kept:", in: conversation)?.line == "Kept: the sidebar search")
    // a tool call and its answer are not: a path or a log line would answer
    // for every conversation that ever ran a command
    precondition(ChatContentSearch.hit("Buổi", in: conversation) == nil)
    precondition(ChatContentSearch.hit("hundred lines", in: conversation) == nil)
    // nothing searched for, nothing found
    precondition(ChatContentSearch.hit("", in: conversation) == nil)
    precondition(ChatContentSearch.hit("sidebar", in: []) == nil)
    precondition(ChatContentSearch.hit("sidebar", in: [event(1, "finished")]) == nil)

    // one line of a long text is answered, cut around the words and marked
    let long = String(repeating: "x", count: 200) + " needle " + String(repeating: "y", count: 200)
    let cut = TextSearch.line(of: long, holding: "needle")
    precondition(cut?.hasPrefix("...") == true && cut?.hasSuffix("...") == true, "cut on both sides: \(cut ?? "nil")")
    precondition(cut?.contains("needle") == true && cut!.count < long.count)
    // the first line holding them is the one answered
    precondition(TextSearch.line(of: "nothing here\none needle\ntwo needle", holding: "needle") == "one needle")
    // a line shorter than the cut comes back as it is
    precondition(TextSearch.line(of: "a needle here", holding: "needle") == "a needle here")
    // a very long row is cut to what a row shows
    let enormous = String(repeating: "p", count: 200) + String(repeating: "q", count: 100) + String(repeating: "p", count: 200)
    let shortened = TextSearch.line(of: enormous, holding: String(repeating: "q", count: 100))
    precondition(shortened?.count == 143 && shortened?.hasSuffix("...") == true, "cut to the limit: \(shortened?.count ?? -1)")
    // nothing found, empty words, and words that are not a pattern
    precondition(TextSearch.line(of: "abc", holding: "needle") == nil)
    precondition(TextSearch.line(of: "abc", holding: "") == nil)
    precondition(TextSearch.line(of: "axb", holding: "a.b") == nil)
    precondition(TextSearch.holds(nil, "a") == false && TextSearch.holds("abc", "B") == true)
    print("ok: a conversation is searched for what it said, never for what its tools ran")
}
