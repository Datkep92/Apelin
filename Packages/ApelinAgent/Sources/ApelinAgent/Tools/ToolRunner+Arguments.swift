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
        var converted: [String: TemplateValue] = [:]
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            converted[name] = try templateValue(value, named: name)
        }
        return converted
    }

    /// One parameter's value as the call gave it; apelin-build judges it
    /// against the parameter's kind, which apelin_template_list names.
    private static func templateValue(_ value: JSONValue, named name: String) throws -> TemplateValue {
        switch value {
        case let .string(text): return .string(text)
        case let .bool(flag): return .boolean(flag)
        case let .int(number): return .integer(number)
        case let .double(number) where number.rounded() == number && abs(number) < 1e15:
            return .integer(Int(number))
        case let .array(items):
            return try .list(items.map { item in
                guard case let .string(text) = item else {
                    throw ToolArgumentError(#"\#(name): a list holds strings only, such as ["com.apple.springboard", "com.apple.Preferences"]"#)
                }
                return text
            })
        default:
            throw ToolArgumentError("\(name) must be a string, boolean, integer or list of strings")
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
                durationMilliseconds: arguments.argInt("duration_ms") ?? UIAction.defaultSwipeMilliseconds,
            )
        case "press_button":
            let button = try arguments.requireString("button")
            guard ["wake", "home", "lock"].contains(button) else {
                throw ToolArgumentError("unknown button \(button); the buttons are wake, home and lock")
            }
            return .pressButton(button)
        case "double_tap":
            return try .doubleTap(
                x: number("x"),
                y: number("y"),
                intervalMilliseconds: arguments.argInt("interval_ms") ?? UIAction.defaultDoubleTapMilliseconds,
            )
        case "long_press":
            return try .longPress(
                x: number("x"),
                y: number("y"),
                durationMilliseconds: arguments.argInt("duration_ms") ?? UIAction.defaultLongPressMilliseconds,
            )
        case "drag":
            return try .drag(
                points: gesturePoints(arguments),
                durationMilliseconds: arguments.argInt("duration_ms") ?? UIAction.defaultSwipeMilliseconds,
                holdMilliseconds: arguments.argInt("hold_ms") ?? UIAction.defaultDragHoldMilliseconds,
            )
        case "press_key": return try .pressKey(arguments.requireString("key"))
        case "open_url": return try .openURL(arguments.requireString("url"))
        case let other: throw ToolArgumentError("unknown action \(other)")
        }
    }

    /// A drag's path: a list of `[x, y]` pairs it presses at, moves through
    /// and releases.
    private static func gesturePoints(_ arguments: JSONValue) throws -> [GesturePoint] {
        let shape = "points is a list of [x, y] pairs, such as [[100, 400], [300, 400]]"
        guard case let .object(object) = arguments, case let .array(items)? = object["points"] else {
            throw ToolArgumentError("missing list 'points': \(shape)")
        }
        guard items.count >= 2 else {
            throw ToolArgumentError("points needs at least two points: \(shape)")
        }
        return try items.map { item in
            guard case let .array(pair) = item, pair.count == 2,
                  let x = coordinate(pair[0]), let y = coordinate(pair[1])
            else {
                throw ToolArgumentError("every point is an [x, y] pair of numbers: \(shape)")
            }
            return GesturePoint(x: x, y: y)
        }
    }

    private static func coordinate(_ value: JSONValue) -> Double? {
        switch value {
        case let .int(number): return Double(number)
        case let .double(number): return number
        default: return nil
        }
    }

    /// The narrowing a screen read asked for. A call that asked for none
    /// gets the tree the device listed.
    static func treeFilter(_ arguments: JSONValue) -> UITreeFilter.Options {
        UITreeFilter.Options(
            match: arguments.argNonEmptyString("match"),
            clickableOnly: arguments.argBool("clickable_only") ?? false,
            limit: arguments.argInt("max_elements"),
        )
    }
}
