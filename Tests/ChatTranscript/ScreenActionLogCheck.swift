import ApelinCore
import ApelinProtocol
import Foundation

/// The journal trail: a screen action's call and its answer each make a
/// line, another tool makes one only when it failed, and nothing else does.
func checkScreenActionLog() {
    func call(_ seq: UInt64, _ tool: String, arguments: String) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: "toolCall", time: Date(timeIntervalSince1970: Double(seq)), payload: .object([
            "id": .string("c\(seq)"), "tool": .string(tool), "arguments": .string(arguments),
        ]))
    }

    func result(_ seq: UInt64, _ tool: String, _ output: String, isError: Bool = false) -> TaskEvent {
        TaskEvent(seq: EventSeq(seq), kind: "toolResult", time: Date(timeIntervalSince1970: Double(seq)), payload: .object([
            "id": .string("c\(seq)"), "tool": .string(tool), "output": .string(output), "isError": .bool(isError),
        ]))
    }

    let interact = AgentToolName.screenInteract.rawValue
    let tap = "{ \"action\" : \"long_press\", \"x\" : 120, \"y\" : 340, \"duration_ms\" : 800 }"
    let lines = ScreenActionLog.lines(in: [
        call(1, interact, arguments: tap),
        result(2, interact, "long press held 0.8 s"),
        call(3, "apelin_screen_read_tree", arguments: "{\n  \"target\" : \"com.apple.Preferences\"\n}"),
        result(4, "apelin_screen_read_tree", "Preferences\n  General\n  Display", isError: true),
        call(5, AgentToolName.shellRun.rawValue, arguments: "{\"command\":\"ls\"}"),
        result(6, AgentToolName.shellRun.rawValue, "ls: no such file\nsecond line"),
        result(7, AgentToolName.shellRun.rawValue, "refused by the user", isError: true),
        TaskEvent(seq: EventSeq(8), kind: "message", time: Date(timeIntervalSince1970: 8), payload: .object([
            "text": .string("Done"), "tool": .string("file_read"),
        ])),
    ])

    // the call and the answer, both under Screen, the arguments on one line
    precondition(lines.count == 5, "a call and an answer per screen action, a failed tool, and nothing else: \(lines)")
    precondition(lines[0] == ScreenActionLog.Line(
        category: ScreenActionLog.screenCategory,
        text: "\(interact) { \"action\" : \"long_press\", \"x\" : 120, \"y\" : 340, \"duration_ms\" : 800 }",
        isProblem: false,
    ))
    precondition(lines[1].category == ScreenActionLog.screenCategory && lines[1].text == "\(interact) → ok: long press held 0.8 s")
    precondition(lines[2].text == "apelin_screen_read_tree { \"target\" : \"com.apple.Preferences\" }", "a call's line breaks join")
    precondition(lines[3].isProblem && lines[3].text == "apelin_screen_read_tree → failed: Preferences", "a failed read keeps its first line only")
    precondition(lines[4].category == ScreenActionLog.toolCategory, "another tool files under Tool")
    precondition(lines[4].isProblem && lines[4].text == "\(AgentToolName.shellRun.rawValue) → failed: refused by the user")

    // a tool that went well, a message that names one, and an event with no
    // payload make no line at all
    precondition(ScreenActionLog.lines(in: [result(1, AgentToolName.shellRun.rawValue, "ok")]).isEmpty)
    precondition(ScreenActionLog.lines(in: [
        TaskEvent(seq: EventSeq(1), kind: "message", time: Date(timeIntervalSince1970: 1), payload: .object([
            "text": .string("Done"), "tool": .string(AgentToolName.shellRun.rawValue),
        ])),
        TaskEvent(seq: EventSeq(2), kind: "finished", time: Date(timeIntervalSince1970: 2)),
    ]).isEmpty)
    precondition(ScreenActionLog.lines(in: []).isEmpty)

    // a long argument list and a long answer are cut, so one row stays one row
    let long = String(repeating: "a", count: 400)
    let cut = ScreenActionLog.lines(in: [call(1, interact, arguments: long), result(2, interact, long)])
    precondition(cut.count == 2 && cut.allSatisfy { $0.text.count < 300 && $0.text.hasSuffix("…") })
    // an answer with no text says only whether it went
    precondition(ScreenActionLog.lines(in: [result(1, interact, "")])[0].text == "\(interact) → ok")
    print("ok: screen actions and failed tools make one journal line each")
}