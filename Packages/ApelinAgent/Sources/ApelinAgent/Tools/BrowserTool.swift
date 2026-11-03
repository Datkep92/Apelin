import ApelinCore
import Foundation

/// Driving a browser by its screen: one call, one thing done, and a page
/// small enough to keep in the conversation.
///
/// A web page read as an accessibility tree is hundreds of rows of prose, and
/// a model that read one to find a link pays for all of it again on every
/// later request of the session. So a read answers a page as a page: its
/// words as one bounded paragraph, the things a tap can drive as a short list
/// of ids, and the address the browser shows — and nothing about the
/// browser's own chrome unless the call asks for it with `scope: all`.
///
/// Nothing here reaches past the screen tools: a read is `readUITree`, an
/// action is `uiAction`, and both pass the host's consent for the screen
/// (`ScreenConsent`). One call is one read or one action and never both, so
/// each one is one consent, and a flow is open, read, click, read.
///
/// There is no page JavaScript: iOS gives an app no way to run script in
/// another app's browser, so what this drives is what a person could touch.
public enum BrowserTool {
    // MARK: - What a call asks for

    public enum Action: String, CaseIterable, Sendable {
        /// Hand an http or https address to the system, which opens it in
        /// whatever app claims it.
        case open
        /// Answer the page: its words, its controls, its address.
        case read
        /// Find what a text names, as elements a click can use.
        case find
        /// Tap one element, by the id a read answered.
        case click
        /// Type into whatever holds the keyboard, after a click on a field.
        case type
        /// Press one key, such as return or command+l.
        case key
        /// Swipe the page, one screenful at a time.
        case scroll
        /// Read the page and say whether it came, or what went wrong.
        case check
    }

    /// What a read covers: the page inside the browser's web area, or the
    /// whole window, the browser's own controls included.
    public enum Scope: String, CaseIterable, Sendable {
        case page
        case all
    }

    /// Which way a scroll moves the page: `down` reads further down it.
    public enum Direction: String, CaseIterable, Sendable {
        case down
        case up
    }

    /// One call, parsed: the approval gate and the run build the same
    /// request from it, so the card names exactly what happens.
    public enum Invocation: Sendable, Hashable {
        case open(url: String)
        case read(targetID: String?, scope: Scope, match: String?, controlsOnly: Bool, maximumControls: Int?)
        case find(targetID: String?, scope: Scope, match: String)
        case click(targetID: String?, elementID: String)
        case type(targetID: String?, text: String)
        case key(targetID: String?, key: String)
        case scroll(targetID: String?, direction: Direction, x: Double, y: Double, distance: Double)
        case check(targetID: String?, scope: Scope, expect: String?)
    }

    // MARK: - What a call answers

    /// One control, or one piece of the page worth talking about: what a tap
    /// needs and nothing else, so twenty links cost twenty short lines.
    public struct Element: Sendable, Hashable, Codable {
        public var id: String
        public var role: String
        public var text: String
        /// What a field holds, when that differs from what it is called.
        public var value: String?
        /// x, y, width and height in points.
        public var frame: [Double]
        /// The middle of the frame: the point a tap lands on the element
        /// itself and on nothing drawn beside it.
        public var tap: [Double]
    }

    public struct Page: Sendable, Hashable, Codable {
        /// The browser's web area, x/y/width/height in points: a scroll
        /// starts from a point inside it.
        public var webArea: [Double]?
        /// How many elements the read answered, before anything was shaped.
        public var elements: Int
        /// What a tap can drive, in the order the page reads.
        public var controls: [Element]
        /// The browser's own controls — address bar, back, tabs — when the
        /// call asked for the whole window; nil for a page read.
        public var browserControls: [Element]?
        /// The page's words, in reading order, in one bounded paragraph.
        public var text: String
        public var textTruncated: Bool
        /// What the address bar shows, when it could be found.
        public var address: String?
        /// What the answer could not do, in plain words: a page with no web
        /// area found, controls left out, an address bar not recognised.
        public var notes: [String]
    }

    public struct Check: Sendable, Hashable, Codable {
        public var loaded: Bool
        /// What is wrong with the page: the browser's own error, a page that
        /// shows nothing, or text the call expected and did not find.
        public var problems: [String]
        public var address: String?
        public var controls: Int
        public var elements: Int
        /// The page's words, as `read` answers them: evidence of what came.
        public var text: String
    }

    /// One answer, whatever the call was: the fields a call does not use are
    /// left out of the JSON.
    public struct Result: Sendable, Hashable, Codable {
        public var action: String
        public var url: String?
        public var clicked: String?
        public var typed: String?
        public var key: String?
        public var scrolled: String?
        /// Whether the device did it, and its own words when it refused or
        /// waited. Absent for a read.
        public var performed: Bool?
        public var message: String?
        public var typedTextMatches: Bool?
        public var fieldValues: [String]?
        public var page: Page?
        public var matches: [Element]?
        public var check: Check?
        public var notes: [String]

        public init(action: Action, notes: [String] = []) {
            self.action = action.rawValue
            self.notes = notes
        }
    }

    // MARK: - Limits

    /// Controls a page read answers: a page with more than this in reach is
    /// read again with `match`.
    public static let maximumControls = 48
    public static let maximumBrowserControls = 24
    public static let maximumMatches = 20
    /// Characters of the page's own words one read answers.
    public static let textBudget = 1200
    /// Characters kept of one element's label or value.
    public static let maximumElementText = 240
    public static let defaultScrollDistance = 500.0
    public static let minimumScrollDistance = 80.0
    public static let maximumScrollDistance = 2000.0
    /// A flick rather than a drag: the page keeps moving a little after the
    /// finger lifts, which is how a screenful is read in one call.
    public static let scrollDurationMilliseconds = 250

    // MARK: - What the browser says when a page did not come

    /// Folded (see `fold`), so the English Safari and the Vietnamese one
    /// match the same list.
    public static let errorPhrases = [
        "safari cannot open the page",
        "cannot open the page",
        "could not open the page",
        "the page could not be loaded",
        "server cannot be found",
        "cannot find the server",
        "server stopped responding",
        "no internet connection",
        "not connected to the internet",
        "this connection is not private",
        "certificate for this website is invalid",
        "too many redirects",
        "the request timed out",
        "safari khong the mo trang",
        "khong the mo trang",
        "khong tim thay may chu",
        "may chu khong phan hoi",
        "khong co ket noi internet",
        "chua ket noi internet",
        "ket noi nay khong phai la rieng tu",
        "trang web khong kha dung",
    ]

    /// A page the site served about its own failure: not the browser's word,
    /// so only a possibility, said as one.
    public static let possibleErrorPhrases = [
        "404 not found",
        "403 forbidden",
        "500 internal server error",
        "502 bad gateway",
        "503 service unavailable",
        "the page you are looking for",
        "khong tim thay trang",
    ]

    // MARK: - Reading the arguments

    public static func invocation(from arguments: JSONValue) throws -> Invocation {
        let name = try arguments.requireString("action").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let action = Action(rawValue: name) else {
            throw ToolArgumentError("action must be one of \(Action.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let target = arguments.argNonEmptyString("target_id")
        switch action {
        case .open:
            let url = try arguments.requireString("url").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isWebURL(url) else {
                throw ToolArgumentError("url must be an http or https address with a host, such as https://example.com.")
            }
            return .open(url: url)
        case .read:
            return .read(
                targetID: target,
                scope: scope(from: arguments),
                match: arguments.argNonEmptyString("match"),
                controlsOnly: arguments.argBool("clickable_only") ?? false,
                maximumControls: arguments.argInt("max_elements").map { min(maximumControls, max(1, $0)) },
            )
        case .find:
            let match = (arguments.argNonEmptyString("match") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty else {
                throw ToolArgumentError("find needs match: the text to look for on the page.")
            }
            return .find(targetID: target, scope: scope(from: arguments), match: match)
        case .click:
            let element = (arguments.argNonEmptyString("element_id") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !element.isEmpty else {
                throw ToolArgumentError("click needs element_id, an id a read or a find answered, such as text:Sign in.")
            }
            return .click(targetID: target, elementID: element)
        case .type:
            let text = try arguments.requireString("text")
            guard !text.isEmpty else { throw ToolArgumentError("type needs text: what to type.") }
            return .type(targetID: target, text: text)
        case .key:
            let key = try arguments.requireString("key").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw ToolArgumentError("key is empty.") }
            return .key(targetID: target, key: key)
        case .scroll:
            let name = (arguments.argNonEmptyString("direction") ?? Direction.down.rawValue).lowercased()
            guard let direction = Direction(rawValue: name) else {
                throw ToolArgumentError("direction must be down or up.")
            }
            guard let x = arguments.argDouble("x"), let y = arguments.argDouble("y") else {
                throw ToolArgumentError("scroll needs x and y: a point on the page, such as the middle of a read's page.webArea.")
            }
            let asked = arguments.argDouble("distance") ?? defaultScrollDistance
            let distance = min(maximumScrollDistance, max(minimumScrollDistance, asked))
            return .scroll(targetID: target, direction: direction, x: x, y: y, distance: distance)
        case .check:
            return .check(targetID: target, scope: scope(from: arguments), expect: arguments.argNonEmptyString("expect"))
        }
    }

    static func scope(from arguments: JSONValue) -> Scope {
        let name = (arguments.argNonEmptyString("scope") ?? Scope.page.rawValue).lowercased()
        return Scope(rawValue: name) ?? .page
    }

    /// Only http and https, as the screen tool takes them: the system hands
    /// anything else to an app that may not be a browser.
    public static func isWebURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    // MARK: - The wire and the card

    /// What the call does on the screen, as the host is asked for it: the
    /// card Ask Before Using the Screen shows names exactly this.
    public var screenControl: ScreenControlApproval {
        switch self {
        case let .open(url):
            .interact(targetID: nil, action: .openURL(url))
        case let .read(targetID, _, _, _, _), let .find(targetID, _, _), let .check(targetID, _, _):
            .readTree(targetID: targetID)
        case let .click(targetID, elementID):
            .interact(targetID: targetID, action: .tapElement(id: elementID))
        case let .type(targetID, text):
            .interact(targetID: targetID, action: .typeText(text))
        case let .key(targetID, key):
            .interact(targetID: targetID, action: .pressKey(key))
        case let .scroll(targetID, direction, x, y, distance):
            .interact(targetID: targetID, action: Self.swipe(direction: direction, x: x, y: y, distance: distance))
        }
    }

    /// The swipe a scroll makes. Reading further down a page is the finger
    /// travelling up it, and the page keeps going a little after it lifts.
    public static func swipe(direction: Direction, x: Double, y: Double, distance: Double) -> UIAction {
        let sign: Double = direction == .down ? -1 : 1
        return .swipe(
            fromX: x,
            fromY: y,
            toX: x,
            toY: max(0, y + sign * distance),
            durationMilliseconds: scrollDurationMilliseconds,
        )
    }

    // MARK: - Page shaping

    /// The tree, sorted into the page and the browser around it.
    struct Shaped {
        var webArea: [Double]?
        var page: [UIElementNode]
        var chrome: [UIElementNode]
        var elements: Int
        var truncated: Bool
        var notes: [String]
    }

    /// Everything the read answered, flattened, split at the web area.
    static func shaped(_ response: ReadUITreeResponse, scope: Scope) -> Shaped {
        var notes: [String] = []
        let all = flattened(response.root)
        let webArea = all.first { isWebArea($0.role) }
        var page = all
        var chrome: [UIElementNode] = []
        if let webArea, let frame = frame(webArea) {
            page = all.filter { node in
                node.id != webArea.id && (frame(of: node).map { isInside($0, frame) } ?? false)
            }
            chrome = all.filter { node in
                node.id != webArea.id && !(frame(of: node).map { isInside($0, frame) } ?? false)
            }
        } else {
            notes.append(
                "No web area was found in the tree, so nothing could be told apart from the browser's own controls: everything the device listed is read as the page."
            )
        }
        if response.truncated == true {
            notes.append("The device cut the tree short, so the page below may be missing some of what is on the screen.")
        }
        if scope == .page && !chrome.isEmpty {
            notes.append(
                "The browser's own controls were not read (\(chrome.count) elements): read again with scope all to drive its address bar, back or tabs."
            )
        }
        return Shaped(
            webArea: webArea.flatMap(frame).map { [$0.x, $0.y, $0.width, $0.height] },
            page: page,
            chrome: chrome,
            elements: response.elementsTotal ?? all.count,
            truncated: response.truncated ?? false,
            notes: notes,
        )
    }

    /// A page, shaped for a conversation: its words, what a tap can drive,
    /// and its address.
    public static func page(_ response: ReadUITreeResponse, scope: Scope, controlsOnly: Bool = false, limit: Int? = nil) -> Page {
        let shaped = shaped(response, scope: scope)
        var notes = shaped.notes
        let fields = shaped.page.filter { isFieldRole($0.role) }

        var controls: [Element] = []
        var text: [String] = []
        var seen = Set<String>()
        for node in shaped.page where !isFieldRole(node.role) || !normalize(node.value ?? "").isEmpty {
            let words = elementText(node)
            let control = isControlRole(node.role)
            if control {
                guard !words.isEmpty else { continue }
                controls.append(element(node))
            } else {
                guard !words.isEmpty, seen.insert(fold(words)).inserted else { continue }
                text.append(words)
            }
        }
        // A field is worth offering even when it holds nothing: that is what
        // a click on it is for.
        for node in fields where elementText(node).isEmpty {
            controls.append(element(node))
        }
        let cap = min(maximumControls, max(1, limit ?? maximumControls))
        if controls.count > cap {
            notes.append("\(controls.count - cap) more controls were left out: read again with match, or click by element id from a find.")
            controls = Array(controls.prefix(cap))
        }
        var body = ""
        var truncated = false
        if controlsOnly {
            if !text.isEmpty {
                notes.append("The page's words were left out as asked: read again without clickable_only to have them.")
            }
        } else {
            (body, truncated) = digest(text)
            if truncated {
                notes.append("The page's words were cut at \(textBudget) characters; read again with match to reach the rest.")
            }
        }
        var browserControls: [Element]?
        if scope == .all {
            let chrome = shaped.chrome.filter { !elementText($0).isEmpty }.map(element)
            if chrome.count > maximumBrowserControls {
                notes.append("\(chrome.count - maximumBrowserControls) of the browser's own controls were left out.")
            }
            browserControls = Array(chrome.prefix(maximumBrowserControls))
        }
        let address = self.address(in: shaped.chrome.isEmpty ? shaped.page : shaped.chrome)
        if address == nil, !shaped.chrome.isEmpty {
            notes.append("The address bar was not recognised, so the answer does not say which page is showing.")
        }
        return Page(
            webArea: shaped.webArea,
            elements: shaped.elements,
            controls: controls,
            browserControls: browserControls,
            text: body,
            textTruncated: truncated,
            address: address,
            notes: notes,
        )
    }

    /// What a search for `text` found, as elements a click can use.
    public static func matches(_ response: ReadUITreeResponse, scope: Scope, text: String) -> (matches: [Element], notes: [String]) {
        let shaped = shaped(response, scope: scope)
        var notes = shaped.notes
        let needle = fold(text)
        let pool = scope == .all ? shaped.page + shaped.chrome : shaped.page
        var found: [Element] = []
        for node in pool {
            let words = elementText(node)
            guard !words.isEmpty else { continue }
            guard fold(words).contains(needle) || fold(node.role).contains(needle) else { continue }
            found.append(element(node))
        }
        if found.count > maximumMatches {
            notes.append("\(found.count - maximumMatches) more elements matched: search for more of the text.")
            found = Array(found.prefix(maximumMatches))
        }
        if found.isEmpty {
            notes.append("Nothing on the page contains “\(text)”. Read the page to see what is there, or search for fewer words.")
        }
        return (found, notes)
    }

    /// Whether the page came, and what is wrong with it when it did not.
    public static func check(
        _ response: ReadUITreeResponse,
        scope: Scope,
        expect: String?,
    ) -> (page: Page, check: Check) {
        let page = page(response, scope: scope)
        let shaped = shaped(response, scope: scope)
        let words = fold((shaped.page + shaped.chrome).map(elementText).joined(separator: " "))
        var problems: [String] = []
        if shaped.page.isEmpty {
            problems.append("Nothing was inside the page: it may still be loading, or the browser shows an empty tab.")
        }
        if let phrase = errorPhrases.first(where: { words.contains($0) }) {
            problems.append("The browser's own error is on the page: “\(phrase)”.")
        }
        let possible = possibleErrorPhrases.filter { words.contains($0) }
        if !possible.isEmpty {
            problems.append(
                "The page reads like a failure of the site itself (\(possible.joined(separator: ", "))): it came, but it may not be what was asked for."
            )
        }
        if let expect, !expect.isEmpty {
            let needle = fold(expect)
            let found = words.contains(needle) || fold(page.address ?? "").contains(needle) || fold(page.text).contains(needle)
            if !found {
                problems.append("The page does not show “\(expect)”.")
            }
        }
        return (page, Check(
            loaded: problems.isEmpty,
            problems: problems,
            address: page.address,
            controls: page.controls.count,
            elements: page.elements,
            text: page.text,
        ))
    }

    // MARK: - Elements

    static func element(_ node: UIElementNode) -> Element {
        let frame = frame(node)
        let words = text(node)
        let value = normalize(node.value ?? "")
        return Element(
            id: node.id,
            role: node.role,
            text: String(words.prefix(maximumElementText)),
            value: !value.isEmpty && value != words ? String(value.prefix(maximumElementText)) : nil,
            frame: frame.map { [$0.x, $0.y, $0.width, $0.height] } ?? [],
            tap: frame.map(tapPoint) ?? [],
        )
    }

    /// What an element is called, or what it holds when it is called nothing.
    static func elementText(_ node: UIElementNode) -> String {
        let label = text(node)
        return label.isEmpty ? normalize(node.value ?? "") : label
    }

    static func text(_ node: UIElementNode) -> String {
        normalize(node.label ?? "")
    }

    static func normalize(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Case and accents away, so a Vietnamese Safari's error and the English
    /// phrase in the list meet: "Không thể mở trang" folds to
    /// "khong the mo trang".
    public static func fold(_ string: String) -> String {
        string
            .lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    // MARK: - Roles

    static func flattened(_ node: UIElementNode, depth: Int = 0) -> [UIElementNode] {
        guard depth < 12 else { return [] }
        return [node] + node.children.flatMap { flattened($0, depth: depth + 1) }
    }

    /// The element a browser's page is drawn in. Safari, Chrome and
    /// Firefox all surface one, and its frame is where the page is.
    static func isWebArea(_ role: String) -> Bool {
        let role = role.lowercased()
        return role.contains("webview") || role.contains("webarea") || role.contains("web area")
            || role == "web" || role.contains("webkit")
    }

    /// Roles that a tap drives. The device sends a role, never a flag, so
    /// this is a reading of the names iOS and its browsers use; an element
    /// read as plain text that is in fact a link still has its id and its
    /// tap point, so it can be clicked by point.
    static func isControlRole(_ role: String) -> Bool {
        let role = role.lowercased()
        let names = [
            "button", "link", "cell", "field", "switch", "toggle", "checkbox", "radio",
            "slider", "stepper", "segmented", "segment", "tab", "menuitem", "menu", "picker",
            "combobox", "popup", "search", "textbox", "disclosure", "adjustable", "stepper",
        ]
        return names.contains { role.contains($0) }
    }

    static func isFieldRole(_ role: String) -> Bool {
        let role = role.lowercased()
        return role.contains("textfield") || role.contains("searchfield") || role.contains("textbox")
            || role.contains("field") || role == "text"
    }

    // MARK: - Frames

    static func frame(_ node: UIElementNode) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard node.frame.count == 4, node.frame[2] > 0, node.frame[3] > 0 else { return nil }
        return (node.frame[0], node.frame[1], node.frame[2], node.frame[3])
    }

    static func tapPoint(_ frame: (x: Double, y: Double, width: Double, height: Double)) -> [Double] {
        [(frame.x + frame.width / 2).rounded(), (frame.y + frame.height / 2).rounded()]
    }

    static func isInside(
        _ node: (x: Double, y: Double, width: Double, height: Double),
        _ area: (x: Double, y: Double, width: Double, height: Double),
    ) -> Bool {
        let centreX = node.x + node.width / 2
        let centreY = node.y + node.height / 2
        return centreX >= area.x - 1 && centreX <= area.x + area.width + 1
            && centreY >= area.y - 1 && centreY <= area.y + area.height + 1
    }

    // MARK: - The address bar

    /// What the browser shows as the address, found by what it holds rather
    /// than by what it is called, which changes with the language.
    static func address(in nodes: [UIElementNode]) -> String? {
        let fields = nodes.filter { isFieldRole($0.role) }
        let values = fields.compactMap { node -> String? in
            let value = normalize(node.value ?? "")
            return looksLikeAddress(value) ? value : nil
        }
        if let value = values.first {
            return value
        }
        // No value reads as an address: the widest field, which in every
        // browser is the address bar, may still say which page is showing.
        let widest = fields
            .compactMap { node -> (value: String, width: Double)? in
                guard let frame = frame(node) else { return nil }
                let value = normalize(node.value ?? "")
                return value.isEmpty ? nil : (value, frame.width)
            }
            .max { $0.width < $1.width }
        return widest?.value
    }

    /// An address, not a placeholder and not a search: one line, no spaces,
    /// and either a scheme or a dot in it.
    static func looksLikeAddress(_ string: String) -> Bool {
        guard !string.isEmpty, string.count <= 300 else { return false }
        let lowered = string.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return true }
        guard !lowered.contains(" "), !lowered.contains("  ") else { return false }
        return lowered.contains(".")
    }

    // MARK: - The page's words

    /// One bounded paragraph of the page, cut on a word where it can.
    static func digest(_ pieces: [String]) -> (String, Bool) {
        var body = ""
        for piece in pieces {
            let needed = body.isEmpty ? piece.count : body.count + 3 + piece.count
            if needed > textBudget {
                if body.isEmpty {
                    return (String(piece.prefix(textBudget)) + "…", true)
                }
                return (body + " …", true)
            }
            body = body.isEmpty ? piece : body + " · " + piece
        }
        return (body, false)
    }
}