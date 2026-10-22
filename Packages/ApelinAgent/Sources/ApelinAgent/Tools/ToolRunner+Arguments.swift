import enum ApelinProtocol.BuildBootstrap
import Foundation
import KWWKAI

extension ToolRunner {
    static func conversationWait(_ arguments: JSONValue) -> Int {
        min(ConversationReadToolRequest.maximumWaitSeconds, max(0, arguments.argInt("wait_seconds") ?? 0))
    }

    static func conversation(_ arguments: JSONValue) throws -> String {
        let id = try arguments.requireString("session_id").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw ToolArgumentError("session_id is empty") }
        return id
    }

    /// The bootstrap a call names, roothide or rootless; nil when it names none.
    static func bootstrap(_ arguments: JSONValue) throws -> String? {
        let bootstrap = arguments.argString("bootstrap")
        guard bootstrap.map({ BuildBootstrap(rawValue: $0) != nil }) ?? true else {
            throw ToolDeniedError(message: "bootstrap must be roothide or rootless")
        }
        return bootstrap
    }

    static func templateValues(_ arguments: JSONValue) throws -> [String: TemplateValue] {
        guard case let .object(object) = arguments, let given = object["values"] else { return [:] }
        guard case let .object(values) = given else { throw ToolArgumentError("values must be an object") }
        return try values.mapValues { value in
            switch value {
            case let .string(text): return .string(text)
            case let .bool(flag): return .boolean(flag)
            case let .int(number): return .integer(number)
            case let .double(number) where number.rounded() == number && abs(number) < 1e15:
                return .integer(Int(number))
            default: throw ToolArgumentError("each value must be a string, boolean or integer")
            }
        }
    }

    static func uiAction(_ arguments: JSONValue) throws -> UIAction {
        func number(_ key: String) throws -> Double {
            guard let value = arguments.argDouble(key) else { throw ToolArgumentError("missing number '\(key)'") }
            return value
        }
        switch try arguments.requireString("action") {
        case "tap": return try .tap(x: number("x"), y: number("y"))
        case "tap_element": return try .tapElement(id: arguments.requireString("element_id"))
        case "type_text": return try .typeText(arguments.requireString("text"))
        case "swipe":
            return try .swipe(
                fromX: number("x"),
                fromY: number("y"),
                toX: number("to_x"),
                toY: number("to_y"),
            )
        case "press_button":
            let button = try arguments.requireString("button")
            guard ["home", "lock", "volume_up", "volume_down"].contains(button) else {
                throw ToolArgumentError("unknown button \(button)")
            }
            return .pressButton(button)
        case let other: throw ToolArgumentError("unknown action \(other)")
        }
    }
}
