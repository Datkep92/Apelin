@testable import ApelinAgent
import ApelinCore
import Foundation
import KWWKAI
import Testing

/// The narrowing a screen read may ask for. A page is hundreds of elements and
/// every one of them is context the model pays for again on each later
/// request, so a read that knows what it wants cuts the answer down in the
/// session's own worker — on the tree the device already sent, never with a
/// second read or a second consent — and says how much it left out.
///
/// Two JSON types meet here on purpose: the tree is `ApelinCore.JSONValue`,
/// which is what the wire carries, and a tool call's arguments are
/// `KWWKAI.JSONValue`, which is what the model sends. Both are named
/// explicitly, so neither file's spelling decides which one a line means.
@Suite("Screen read filter")
struct UITreeFilterTests {
    private static func element(
        label: String = "",
        value: String = "",
        identifier: String = "",
        role: String = "button",
        clickable: Bool = true,
    ) -> ApelinCore.JSONValue {
        .object([
            "label": .string(label),
            "value": .string(value),
            "identifier": .string(identifier),
            "role": .string(role),
            "enabled": .bool(true),
            "clickable": .bool(clickable),
            "visible": .bool(true),
        ])
    }

    private static func tree(_ elements: [ApelinCore.JSONValue], truncated: Bool = false) -> ApelinCore.JSONValue {
        .object([
            "pid": .number(42),
            "elements": .array(elements),
            "truncated": .bool(truncated),
        ])
    }

    private static func labels(_ tree: ApelinCore.JSONValue) -> [String] {
        guard case let .array(elements)? = tree["elements"] else { return [] }
        return elements.compactMap { $0["label"]?.stringValue }
    }

    @Test
    func `a read that asked for nothing answers the tree the device listed`() {
        let tree = Self.tree([Self.element(label: "General"), Self.element(label: "Wi-Fi", clickable: false)])
        #expect(UITreeFilter.applying(UITreeFilter.Options(), to: tree) == tree)
        #expect(UITreeFilter.applying(UITreeFilter.Options(match: ""), to: tree) == tree)
        #expect(UITreeFilter.Options().isEmpty)
        #expect(UITreeFilter.Options(match: "").isEmpty, "an empty match is no match")
        #expect(!UITreeFilter.Options(clickableOnly: true).isEmpty)
        #expect(!UITreeFilter.Options(limit: 5).isEmpty)
    }

    @Test
    func `a text match keeps only the elements that hold it, and counts what it left`() {
        let tree = Self.tree([
            Self.element(label: "Café"),
            Self.element(label: "Wi-Fi", value: "On"),
            Self.element(label: "General", identifier: "com.apple.general", role: "cell"),
        ])

        let accent = UITreeFilter.applying(UITreeFilter.Options(match: "CAFE"), to: tree)
        #expect(Self.labels(accent) == ["Café"], "case and diacritics do not decide a match")
        #expect(accent["elementsTotal"]?.doubleValue == 3)
        #expect(accent["elementsMatched"]?.doubleValue == 1)
        #expect(accent["truncated"]?.boolValue == false, "nothing was cut short")

        #expect(Self.labels(UITreeFilter.applying(UITreeFilter.Options(match: "com.apple"), to: tree)) == ["General"],
                "an identifier matches too")
        #expect(Self.labels(UITreeFilter.applying(UITreeFilter.Options(match: "on"), to: tree)) == ["Wi-Fi"],
                "so does a value")
    }

    @Test
    func `a match that keeps nothing says the page had elements, so it is not read as empty`() {
        let tree = Self.tree([Self.element(label: "General"), Self.element(label: "Privacy")])
        let filtered = UITreeFilter.applying(UITreeFilter.Options(match: "zzz"), to: tree)
        #expect(Self.labels(filtered).isEmpty)
        #expect(filtered["elementsTotal"]?.doubleValue == 2, "the page is not read as empty")
        #expect(filtered["elementsMatched"]?.doubleValue == 0)
    }

    @Test
    func `clickable only keeps what a tap can land on`() {
        let tree = Self.tree([
            Self.element(label: "General", clickable: true),
            Self.element(label: "A paragraph", clickable: false),
            Self.element(label: "Back", clickable: true),
        ])
        let filtered = UITreeFilter.applying(UITreeFilter.Options(clickableOnly: true), to: tree)
        #expect(Self.labels(filtered) == ["General", "Back"])
        #expect(filtered["elementsTotal"]?.doubleValue == 3)
        #expect(filtered["truncated"]?.boolValue == false)
    }

    @Test
    func `a limit cuts short and says so, where a limit that fits cuts nothing`() {
        let tree = Self.tree((1 ... 5).map { Self.element(label: "Row \($0)") })

        let cut = UITreeFilter.applying(UITreeFilter.Options(limit: 2), to: tree)
        #expect(Self.labels(cut) == ["Row 1", "Row 2"], "the first ones, in the order the device listed")
        #expect(cut["truncated"]?.boolValue == true)
        #expect(cut["elementsMatched"]?.doubleValue == 5)

        let fits = UITreeFilter.applying(UITreeFilter.Options(limit: 9), to: tree)
        #expect(Self.labels(fits).count == 5)
        #expect(fits["truncated"]?.boolValue == false)

        let zero = UITreeFilter.applying(UITreeFilter.Options(limit: 0), to: tree)
        #expect(Self.labels(zero).count == 1, "a limit below one keeps one rather than answering nothing")
    }

    @Test
    func `a limit above the cap is held to the cap, and a tree the device cut short stays cut`() {
        let many = Self.tree((1 ... (UITreeFilter.maximumLimit + 5)).map { Self.element(label: "Row \($0)") })
        let capped = UITreeFilter.applying(UITreeFilter.Options(limit: 100_000), to: many)
        #expect(Self.labels(capped).count == UITreeFilter.maximumLimit)
        #expect(capped["truncated"]?.boolValue == true)

        let short = Self.tree([Self.element(label: "General")], truncated: true)
        #expect(UITreeFilter.applying(UITreeFilter.Options(clickableOnly: true), to: short)["truncated"]?.boolValue == true)
    }

    @Test
    func `match and limit together: the limit applies to what matched, not to the page`() {
        let tree = Self.tree([
            Self.element(label: "Back"),
            Self.element(label: "Item one", role: "cell", clickable: true),
            Self.element(label: "Item two", role: "cell", clickable: true),
            Self.element(label: "Item three", role: "cell", clickable: true),
        ])
        let filtered = UITreeFilter.applying(UITreeFilter.Options(match: "item", clickableOnly: true, limit: 2), to: tree)
        #expect(Self.labels(filtered) == ["Item one", "Item two"])
        #expect(filtered["elementsTotal"]?.doubleValue == 4)
        #expect(filtered["elementsMatched"]?.doubleValue == 3)
        #expect(filtered["truncated"]?.boolValue == true)
    }

    @Test
    func `a tree that is not an element list is answered as it arrived`() {
        let answers: [ApelinCore.JSONValue] = [
            .null,
            .string("not a tree"),
            .object(["pid": .number(1)]),
            .object(["elements": .string("not a list")]),
        ]
        for tree in answers {
            #expect(UITreeFilter.applying(UITreeFilter.Options(clickableOnly: true), to: tree) == tree)
        }
    }

    @Test
    func `the tool's arguments become the filter, and nothing sent keeps nothing`() {
        #expect(ToolRunner.treeFilter(.object([:])).isEmpty)
        #expect(ToolRunner.treeFilter(.object(["match": .string("")])).isEmpty)
        #expect(ToolRunner.treeFilter(.object(["max_depth": .int(6)])).isEmpty, "max_depth is the device's, not the filter's")

        #expect(ToolRunner.treeFilter(.object([
            "match": .string("Settings"),
            "clickable_only": .bool(true),
            "max_elements": .int(20),
        ])) == UITreeFilter.Options(match: "Settings", clickableOnly: true, limit: 20))
        #expect(ToolRunner.treeFilter(.object(["clickable_only": .bool(false), "max_elements": .int(3)]))
            == UITreeFilter.Options(clickableOnly: false, limit: 3))
    }
}
