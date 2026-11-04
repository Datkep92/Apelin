import ApelinCore
import Foundation
import KWWKAgent
import KWWKAI

extension ToolRunner {
    /// How deep one browser read goes: a browser's page sits well below its
    /// own window, and a web page's controls below that.
    static let browserReadDepth = 40

    /// One browser call: one read or one action, never both, so each call is
    /// one consent on the screen and one thing to check afterwards.
    func runBrowser(_ invocation: BrowserTool.Invocation, context: HostCallContext) async throws -> AgentToolResult {
        switch invocation {
        case let .open(url):
            var result = BrowserTool.Result(action: .open)
            result.url = url
            fill(&result, try await backend.uiAction(UIActionRequest(context: context, targetID: nil, action: .openURL(url))))
            result.notes = [
                "The address went to the system, which opens an http or https one in whatever app claims it. Nothing was read: call this tool again with action read to see the page.",
                "If a browser did not come to the front, the address opened in another app: read with scope all to see which app is showing.",
            ]
            return answer(result)

        case let .read(targetID, scope, match, controlsOnly, limit):
            // Nothing is narrowed away on the wire: the whole tree is shaped
            // into a page below, and a filter would only save bytes the
            // device has already sent.
            let response = try await backend.readUITree(ReadUITreeRequest(
                context: context,
                targetID: targetID,
                maxDepth: Self.browserReadDepth,
                match: match,
            ))
            var result = BrowserTool.Result(action: .read)
            result.page = BrowserTool.page(response, scope: scope, controlsOnly: controlsOnly, limit: limit)
            return answer(result)

        case let .find(targetID, scope, match):
            let response = try await backend.readUITree(ReadUITreeRequest(
                context: context,
                targetID: targetID,
                maxDepth: Self.browserReadDepth,
                match: match,
                maxElements: BrowserTool.maximumMatches,
            ))
            let found = BrowserTool.matches(response, scope: scope, text: match)
            var result = BrowserTool.Result(action: .find)
            result.matches = found.matches
            result.notes = found.notes
            return answer(result)

        case let .click(targetID, elementID):
            var result = BrowserTool.Result(action: .click)
            result.clicked = elementID
            fill(&result, try await backend.uiAction(UIActionRequest(
                context: context,
                targetID: targetID,
                action: .tapElement(id: elementID),
            )))
            result.notes = [
                "What the tap did is not in this answer: read the page to see what came of it.",
            ]
            return answer(result)

        case let .type(targetID, text):
            var result = BrowserTool.Result(action: .type)
            result.typed = text
            fill(&result, try await backend.uiAction(UIActionRequest(
                context: context,
                targetID: targetID,
                action: .typeText(text),
            )))
            result.notes = []
            if result.typedTextMatches == false {
                result.notes.append(
                    "The field does not hold the text that went in: click the field before typing, or read the page to see which field took it."
                )
            }
            return answer(result)

        case let .key(targetID, key):
            var result = BrowserTool.Result(action: .key)
            result.key = key
            fill(&result, try await backend.uiAction(UIActionRequest(
                context: context,
                targetID: targetID,
                action: .pressKey(key),
            )))
            result.notes = [
                "A key goes to whatever holds the keyboard, so click a field first when the key is meant for it.",
            ]
            return answer(result)

        case let .scroll(targetID, direction, x, y, distance):
            var result = BrowserTool.Result(action: .scroll)
            result.scrolled = direction.rawValue
            fill(&result, try await backend.uiAction(UIActionRequest(
                context: context,
                targetID: targetID,
                action: BrowserTool.swipe(direction: direction, x: x, y: y, distance: distance),
            )))
            result.notes = [
                "The page moved about \(Int(distance)) points \(direction.rawValue): read again to see what is there now.",
            ]
            return answer(result)

        case let .check(targetID, scope, expect):
            let response = try await backend.readUITree(ReadUITreeRequest(
                context: context,
                targetID: targetID,
                maxDepth: Self.browserReadDepth,
            ))
            let (_, check) = BrowserTool.check(response, scope: scope, expect: expect)
            var result = BrowserTool.Result(action: .check)
            result.check = check
            result.notes = []
            return answer(result)
        }
    }

    /// The device's own words about what it did, passed through as they are.
    private func fill(_ result: inout BrowserTool.Result, _ response: UIActionResponse) {
        result.performed = response.performed
        result.message = response.message.isEmpty ? nil : response.message
        result.typedTextMatches = response.typedTextMatches
        result.fieldValues = response.fieldValues
        if !response.performed {
            result.notes.append("The device did not do it: its message above says why.")
        }
    }

    private func answer(_ result: BrowserTool.Result) -> AgentToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(result)) ?? Data("{}".utf8)
        return AgentToolResult(content: [.text(TextContent(text: String(decoding: data, as: UTF8.self)))])
    }
}