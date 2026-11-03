import ApelinCore
import Foundation

/// Narrows the element list a screen read hands back, before the model pays
/// for it.
///
/// A page is hundreds of elements — a System Settings screen is one, a web
/// page is more — and every element sent is context the model pays for on
/// every later request of the session. The filter runs in the session's own
/// worker, on the answer it has already been given: no second device call, no
/// second approval, nothing new on the wire. One read is still one consent,
/// whether it answers three elements or three hundred.
///
/// It never guesses. An element is dropped only because the caller asked for
/// it to be dropped, and the answer says how many were left out
/// (`elementsTotal`) and how many survived the text match (`elementsMatched`),
/// so a model that filtered too far can read again without a filter instead
/// of concluding the page is empty.
public enum UITreeFilter {
    /// The most a caller may ask for. A page bigger than this wants a text
    /// match, not a bigger number.
    public static let maximumLimit = 1000

    public struct Options: Sendable, Equatable {
        /// Text an element's label, value, identifier or role must contain,
        /// case- and diacritic-insensitively, to be kept.
        public var match: String?
        /// Keep only elements a tap can land on: buttons, links, fields,
        /// switches. What to reach for when a page's text drowns its control.
        public var clickableOnly: Bool
        /// How many elements to keep at most; nil keeps every one that
        /// matched.
        public var limit: Int?

        public init(match: String? = nil, clickableOnly: Bool = false, limit: Int? = nil) {
            self.match = match
            self.clickableOnly = clickableOnly
            self.limit = limit
        }

        /// Nothing asked for: the tree is answered as the device listed it.
        public var isEmpty: Bool {
            (match?.isEmpty ?? true) && !clickableOnly && limit == nil
        }
    }

    /// The tree with its element list narrowed. A tree that is not an object
    /// with an element list, or a call that asked for no filter, is answered
    /// exactly as it arrived.
    public static func applying(_ options: Options, to tree: JSONValue) -> JSONValue {
        guard !options.isEmpty, case .object(var root) = tree else { return tree }
        guard case let .array(elements)? = root["elements"] else { return tree }

        let matched = elements.filter { keeps($0, options: options) }
        let limit = options.limit.map { max(1, min($0, maximumLimit)) } ?? matched.count
        let kept = Array(matched.prefix(limit))

        root["elements"] = .array(kept)
        root["elementsTotal"] = .number(Double(elements.count))
        root["elementsMatched"] = .number(Double(matched.count))
        // What the device already cut short stays cut, and a limit that bit is
        // cut short too, so a caller never reads a filtered tree as a whole one.
        root["truncated"] = .bool((root["truncated"]?.boolValue ?? false) || kept.count < matched.count)
        return .object(root)
    }

    private static func keeps(_ element: JSONValue, options: Options) -> Bool {
        if options.clickableOnly, element["clickable"]?.boolValue != true { return false }
        guard let needle = options.match, !needle.isEmpty else { return true }
        // The four fields a read is worth matching on; all of them are strings
        // in the tree the device answers.
        let haystack = ["label", "value", "identifier", "role"]
            .compactMap { element[$0]?.stringValue }
            .joined(separator: "\n")
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
