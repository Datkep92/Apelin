@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

/// What models send for a parameter they mean to leave out — `null`, `""`,
/// `[]`, `{}` — reaches no tool as given.
@Suite("Tool arguments")
struct ToolArgumentTests {
    @Test
    func `an empty optional argument is dropped, a required or meaningful one kept`() {
        #expect(ToolArguments.normalized(["name": "apelin-tweak-development", "file": ""], for: .skillRead) == ["name": "apelin-tweak-development"])
        #expect(ToolArguments.normalized(
            ["argv": [], "command": "ls", "cwd": "", "timeout_seconds": .null],
            for: .shellRun,
        ) == ["command": "ls"])
        #expect(ToolArguments.normalized(["template": "t", "name": "n", "values": [:]], for: .projectCreate) == ["template": "t", "name": "n"])
        #expect(ToolArguments.normalized(["path": "a.m", "content": ""], for: .fileWrite) == ["path": "a.m", "content": ""],
                "an empty file is a file")
        #expect(ToolArguments.normalized(["name": "", "email": ""], for: .gitSetAuthor) == ["name": "", "email": ""],
                "an empty author field clears it")
        #expect(ToolArguments.normalized(["after_seq": 0, "session_id": "s"], for: .conversationRead) == ["after_seq": 0, "session_id": "s"],
                "zero and false are values")
    }

    @Test
    func `shell_run takes the command beside an empty argv, and refuses two forms`() throws {
        let normalized = ToolArguments.normalized(["argv": [], "command": "ls -la"], for: .shellRun)
        #expect(try CommandClassifier.classify(normalized) == .argv(["ls", "-la"]))
        #expect(throws: ToolArgumentError.self) {
            try CommandClassifier.classify(["argv": ["ls"], "command": "ls"])
        }
        #expect(throws: ToolArgumentError.self) {
            try CommandClassifier.classify(["command": "ls", "script": "ls", "interpreter": "sh"])
        }
    }

    @Test
    func `press_button takes wake, home and lock, and nothing it cannot press`() throws {
        for button in ["wake", "home", "lock"] {
            #expect(try ToolRunner.uiAction(["action": "press_button", "button": .string(button)]) == .pressButton(button))
        }
        for button in ["volume_up", "volume_down", "power", ""] {
            #expect(throws: ToolArgumentError.self) {
                try ToolRunner.uiAction(["action": "press_button", "button": .string(button)])
            }
        }
    }

    @Test
    func `a swipe takes the duration it is given, 300 ms when none`() throws {
        let swipe = try ToolRunner.uiAction(["action": "swipe", "x": 10, "y": 20, "to_x": 10, "to_y": 400])
        #expect(swipe == .swipe(fromX: 10, fromY: 20, toX: 10, toY: 400, durationMilliseconds: 300))
        let slow = try ToolRunner.uiAction(["action": "swipe", "x": 10, "y": 20, "to_x": 10, "to_y": 400, "duration_ms": 1200])
        #expect(slow == .swipe(fromX: 10, fromY: 20, toX: 10, toY: 400, durationMilliseconds: 1200))
    }

    @Test
    func `a double tap and a long press take their durations, and the defaults when none`() throws {
        #expect(try ToolRunner.uiAction(["action": "double_tap", "x": 30, "y": 40])
            == .doubleTap(x: 30, y: 40, intervalMilliseconds: 100))
        #expect(try ToolRunner.uiAction(["action": "double_tap", "x": 30, "y": 40, "interval_ms": 250])
            == .doubleTap(x: 30, y: 40, intervalMilliseconds: 250))
        #expect(try ToolRunner.uiAction(["action": "long_press", "x": 5, "y": 6])
            == .longPress(x: 5, y: 6, durationMilliseconds: 700))
        #expect(try ToolRunner.uiAction(["action": "long_press", "x": 5, "y": 6, "duration_ms": 1500])
            == .longPress(x: 5, y: 6, durationMilliseconds: 1500))

        let withoutAPoint: [JSONValue] = [
            ["action": "double_tap", "y": 40],
            ["action": "long_press", "x": 5],
        ]
        for arguments in withoutAPoint {
            #expect(throws: ToolArgumentError.self) { try ToolRunner.uiAction(arguments) }
        }
    }

    @Test
    func `a drag takes its path, its duration and its hold, and needs two points with numbers in them`() throws {
        let drag = try ToolRunner.uiAction([
            "action": "drag",
            "points": [[100, 400], [300, 400], [300, 700]],
            "duration_ms": 800,
            "hold_ms": 400,
        ])
        #expect(drag == .drag(
            points: [
                GesturePoint(x: 100, y: 400),
                GesturePoint(x: 300, y: 400),
                GesturePoint(x: 300, y: 700),
            ],
            durationMilliseconds: 800,
            holdMilliseconds: 400,
        ))
        #expect(try ToolRunner.uiAction(["action": "drag", "points": [[0, 0], [10, 20]]])
            == .drag(
                points: [GesturePoint(x: 0, y: 0), GesturePoint(x: 10, y: 20)],
                durationMilliseconds: 300,
                holdMilliseconds: 500,
            ))

        let bad: [JSONValue] = [
            ["action": "drag"],
            ["action": "drag", "points": []],
            ["action": "drag", "points": [[100, 400]]],
            ["action": "drag", "points": [[100, 400], [300]]],
            ["action": "drag", "points": [[100, 400], ["300", 400]]],
        ]
        for arguments in bad {
            #expect(throws: ToolArgumentError.self) { try ToolRunner.uiAction(arguments) }
        }
    }

    @Test
    func `press_key and open_url take the text they are given, and need it`() throws {
        #expect(try ToolRunner.uiAction(["action": "press_key", "key": "command+a"])
            == .pressKey("command+a"))
        #expect(try ToolRunner.uiAction(["action": "open_url", "url": "https://example.com/x"])
            == .openURL("https://example.com/x"))

        let bad: [JSONValue] = [
            ["action": "press_key"],
            ["action": "open_url"],
            ["action": "double_click", "x": 1, "y": 2],
        ]
        for arguments in bad {
            #expect(throws: ToolArgumentError.self) { try ToolRunner.uiAction(arguments) }
        }
    }
}
