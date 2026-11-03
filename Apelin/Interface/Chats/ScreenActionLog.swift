import ApelinCore
import ApelinProtocol
import Foundation

/// What an agent's tools did to the screen, and what failed, as one line
/// each for the launch journal: a screen action when it is asked for and
/// again when it answers, and every other tool's failure. The worker that
/// runs a tool keeps no history and the call's two ends are only together
/// in the app, which reads them once, so the trail is made here and written
/// by `ScreenActionJournal`; Settings ▸ Logs reads it back per launch.
enum ScreenActionLog {
    /// One journal line: the category it files under, the text, and whether
    /// it records something going wrong.
    struct Line: Equatable {
        let category: String
        let text: String
        let isProblem: Bool
    }

    /// The tools whose whole point is the screen: what they did is worth a
    /// line whichever way it went, where another tool earns one only when
    /// it failed.
    static let screenTools: Set<String> = [
        AgentToolName.screenInteract.rawValue,
        AgentToolName.screenReadTree.rawValue,
        AgentToolName.screenCapture.rawValue,
        AgentToolName.browser.rawValue,
    ]

    static let screenCategory = "Screen"
    static let toolCategory = "Tool"

    /// How much of a call's arguments, or of an answer's first line, a line
    /// keeps before it ends in an ellipsis.
    private static let width = 240

    /// The lines `events` make, in the order they arrived. A call the model
    /// made of a screen tool, then its answer, by the name each event
    /// carries: nothing pairs the two, so a batch that holds only one of
    /// them still reads.
    static func lines(in events: [TaskEvent]) -> [Line] {
        events.compactMap { event in
            guard let payload = event.payload, let tool = payload["tool"]?.stringValue else { return nil }
            let onScreen = screenTools.contains(tool)
            switch event.kind {
            case "toolCall":
                guard onScreen else { return nil }
                let arguments = flat(payload["arguments"]?.stringValue ?? "")
                return Line(
                    category: screenCategory,
                    text: arguments.isEmpty ? tool : "\(tool) \(arguments)",
                    isProblem: false,
                )
            case "toolResult":
                let failed = payload["isError"]?.boolValue == true
                guard onScreen || failed else { return nil }
                let output = firstLine(payload["output"]?.stringValue ?? "")
                let verdict = failed ? "failed" : "ok"
                return Line(
                    category: onScreen ? screenCategory : toolCategory,
                    text: output.isEmpty ? "\(tool) → \(verdict)" : "\(tool) → \(verdict): \(output)",
                    isProblem: failed,
                )
            default:
                return nil
            }
        }
    }

    /// `text` on one line, cut to `width`: a call's arguments are read in a
    /// journal row that keeps no line breaks.
    private static func flat(_ text: String) -> String {
        var line = text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
        while line.contains("  ") {
            line = line.replacingOccurrences(of: "  ", with: " ")
        }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.count > width ? String(line.prefix(width)) + "…" : line
    }

    /// The first line of `text`, made short the same way: a tool's answer
    /// can run to hundreds of lines and the journal says what it was.
    private static func firstLine(_ text: String) -> String {
        flat(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "")
    }
}