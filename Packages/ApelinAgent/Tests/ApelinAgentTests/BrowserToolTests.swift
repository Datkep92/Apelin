@testable import ApelinAgent
import ApelinCore
import Testing

/// `apelin_browser`: what a call is allowed to say, what a page answers, and
/// what it tells the model when the page did not come. All of it over a tree
/// the device already sent, so no browser is opened here.
@Suite("Driving a browser as a page")
struct BrowserToolTests {
    private func invocation(_ fields: [String: JSONValue]) throws -> BrowserTool.Invocation {
        try BrowserTool.invocation(from: .object(fields))
    }

    @Test
    func `each action asks for the fields it needs`() throws {
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("wander")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("find")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("find"), "match": .string("   ")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("click")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("type")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("key"), "key": .string("  ")]) }
        #expect(throws: ToolArgumentError.self) { try invocation(["action": .string("scroll"), "x": .number(10)]) }
        #expect(throws: ToolArgumentError.self) {
            try invocation(["action": .string("open"), "url": .string("javascript:alert(1)")])
        }
        #expect(throws: ToolArgumentError.self) {
            try invocation(["action": .string("scroll"), "direction": .string("sideways"), "x": .number(1), "y": .number(2)])
        }
    }

    @Test
    func `an address is http or https, and nothing else`() {
        #expect(BrowserTool.isWebURL("https://example.com/a?b=c"))
        #expect(BrowserTool.isWebURL("http://example.com"))
        #expect(!BrowserTool.isWebURL("javascript:alert(1)"))
        #expect(!BrowserTool.isWebURL("example.com"))
        #expect(!BrowserTool.isWebURL("https://"))
        #expect(!BrowserTool.isWebURL("file:///etc/hosts"))
    }

    /// What a click needs is an id a read answered, and the whole target —
    /// "sign in" written by hand is not one.
    @Test
    func `a click takes an id a read answered and a search takes words`() throws {
        guard case let .click(_, elementID) = try invocation([
            "action": .string("click"),
            "element_id": .string("  text:Sign in  "),
            "target_id": .string("com.apple.mobilesafari"),
        ]) else {
            Issue.record("a click was not read as one")
            return
        }
        #expect(elementID == "text:Sign in")

        guard case let .find(_, scope, match) = try invocation([
            "action": .string("find"),
            "match": .string("  Sign in  "),
        ]) else {
            Issue.record("a find was not read as one")
            return
        }
        #expect(scope.rawValue == "page")
        #expect(match == "Sign in")
    }

    /// A scroll keeps the point the call gave it: the point is what the page
    /// is scrolled at, and only its travel is bounded.
    @Test
    func `a scroll keeps its point and bounds only its travel`() throws {
        guard case let .scroll(targetID, direction, x, y, distance) = try invocation([
            "action": .string("scroll"),
            "x": .number(180),
            "y": .number(420),
            "distance": .number(9000),
        ]) else {
            Issue.record("a scroll was not read as one")
            return
        }
        #expect(targetID == nil)
        #expect(direction.rawValue == "down")
        #expect(x == 180)
        #expect(y == 420)
        #expect(distance == BrowserTool.maximumScrollDistance)

        guard case let .read(_, _, _, controlsOnly, maximumControls) = try invocation([
            "action": .string("read"),
            "clickable_only": .bool(true),
            "max_elements": .number(0),
        ]) else {
            Issue.record("a read was not read as one")
            return
        }
        #expect(controlsOnly)
        #expect(maximumControls == 1)
    }

    /// Whatever the action, the user is asked about what it touches: the
    /// screen for a read, the one thing for everything else.
    @Test
    func `every action asks for exactly what it touches`() throws {
        #expect(try invocation(["action": .string("read")]).screenControl == .readTree(targetID: nil))
        #expect(try invocation([
            "action": .string("find"), "match": .string("x"), "target_id": .string("Safari"),
        ]).screenControl == .readTree(targetID: "Safari"))
        #expect(try invocation([
            "action": .string("click"), "element_id": .string("link"),
        ]).screenControl == .interact(targetID: nil, action: .tapElement(id: "link")))
        #expect(try invocation([
            "action": .string("key"), "key": .string("return"),
        ]).screenControl == .interact(targetID: nil, action: .pressKey("return")))
        guard case let .interact(_, action) = try invocation([
            "action": .string("open"), "url": .string("https://example.com"),
        ]).screenControl else {
            Issue.record("opening a url did not ask for a screen action")
            return
        }
        #expect(action == .openURL("https://example.com"))
    }

    /// One window as the device lists it: the address bar and Back outside
    /// the web area, the page's words and its controls inside it.
    private var tree: ReadUITreeResponse {
        ReadUITreeResponse(root: UIElementNode(id: "screen", role: "application", label: "pid 1", children: [
            UIElementNode(
                id: "Address",
                role: "textField",
                value: "https://example.com",
                frame: [20, 50, 300, 40],
            ),
            UIElementNode(id: "Page", role: "webArea", frame: [0, 100, 375, 700], children: [
                UIElementNode(id: "title", role: "staticText", label: "Example Domain", frame: [10, 120, 300, 30]),
                UIElementNode(id: "example_link", role: "link", label: "More information", frame: [10, 200, 200, 20]),
                UIElementNode(id: "query", role: "searchField", frame: [10, 300, 300, 30]),
            ]),
            UIElementNode(id: "Back", role: "button", label: "Back", frame: [10, 50, 40, 40]),
        ]))
    }

    /// A page read answers the page: its words, what a tap drives, and the
    /// address — and, read as the whole window, the browser's own controls.
    @Test
    func `a page read answers the page and the whole window answers the browser too`() {
        let page = BrowserTool.page(tree, scope: .page)
        #expect(page.address == "https://example.com")
        #expect(page.text.contains("Example Domain"))
        #expect(page.controls.map(\.id) == ["example_link", "query"])
        #expect(page.browserControls == nil)
        #expect(page.webArea == [0, 100, 375, 700])
        #expect(page.elements == 7)
        #expect(page.notes.contains { $0.contains("scope all") })
        // A field holding nothing is still worth offering: that is what a
        // click on it is for.
        #expect(page.controls.last?.value == nil)

        let wholeWindow = BrowserTool.page(tree, scope: .all)
        #expect(wholeWindow.browserControls?.map(\.id) == ["Address", "Back"])
        #expect(wholeWindow.controls.map(\.id) == ["example_link", "query"])
    }

    /// One tap point, in the middle of the element, and the page's words left
    /// out when the call asked for controls only.
    @Test
    func `a control carries the point a tap lands on`() {
        let page = BrowserTool.page(tree, scope: .page)
        #expect(page.controls.first?.tap == [110, 210])
        #expect(page.controls.first?.frame == [10, 200, 200, 20])

        let controlsOnly = BrowserTool.page(tree, scope: .page, controlsOnly: true)
        #expect(controlsOnly.text.isEmpty)
        #expect(controlsOnly.notes.contains { $0.contains("clickable_only") })
    }

    /// A read's cap is said out loud, so a model reads again rather than
    /// calling a long page short.
    @Test
    func `a page longer than the cap says what it left out`() {
        let page = BrowserTool.page(tree, scope: .page, limit: 1)
        #expect(page.controls.map(\.id) == ["example_link"])
        #expect(page.notes.contains { $0.contains("1 more control") })
    }

    /// A search finds by words or by role, says what it could not find rather
    /// than answering nothing, and can reach the browser's own controls.
    @Test
    func `a search finds words, roles, and says what it did not find`() {
        let found = BrowserTool.matches(tree, scope: .page, text: "more information")
        #expect(found.matches.map(\.id) == ["example_link"])
        #expect(found.notes.contains { $0.contains("scope all") })

        let byRole = BrowserTool.matches(tree, scope: .page, text: "link")
        #expect(byRole.matches.map(\.id) == ["example_link"])

        let missing = BrowserTool.matches(tree, scope: .page, text: "no such words")
        #expect(missing.matches.isEmpty)
        #expect(missing.notes.contains { $0.contains("no such words") })

        let chrome = BrowserTool.matches(tree, scope: .all, text: "Back")
        #expect(chrome.matches.map(\.id) == ["Back"])
        let pageOnly = BrowserTool.matches(tree, scope: .page, text: "Back")
        #expect(pageOnly.matches.isEmpty)
    }

    /// The check is what tells a model the page came: the browser's own
    /// failure is named, and so is text the call expected and did not find.
    @Test
    func `a page that did not come is named, and so is a word that is missing`() {
        let error = ReadUITreeResponse(root: UIElementNode(id: "screen", role: "application", children: [
            UIElementNode(id: "Page", role: "webArea", frame: [0, 100, 375, 700], children: [
                UIElementNode(
                    id: "error",
                    role: "staticText",
                    label: "Safari cannot open the page because the server cannot be found.",
                    frame: [10, 120, 300, 60],
                ),
            ]),
        ]))
        let named = BrowserTool.check(error, scope: .page, expect: "Example Domain")
        #expect(!named.check.loaded)
        #expect(named.check.problems.contains { $0.contains("cannot open the page") })
        #expect(named.check.problems.contains { $0.contains("Example Domain") })

        let empty = ReadUITreeResponse(root: UIElementNode(id: "screen", role: "application", children: [
            UIElementNode(id: "Page", role: "webArea", frame: [0, 100, 375, 700]),
        ]))
        let blank = BrowserTool.check(empty, scope: .page, expect: nil)
        #expect(!blank.check.loaded)
        #expect(blank.check.problems.contains { $0.contains("Nothing was inside the page") })

        let good = BrowserTool.check(tree, scope: .page, expect: "More information")
        #expect(good.check.loaded)
        #expect(good.check.problems.isEmpty)
        #expect(good.check.address == "https://example.com")
        #expect(good.check.controls == 2)
    }
}
