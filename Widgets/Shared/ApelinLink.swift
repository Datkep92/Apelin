import Foundation

/// An `apelin://` link: what a widget, the Live Activity, a link in a
/// conversation or another app opens.
///
/// - `apelin://conversation/<id>` opens a conversation: `<id>` is its agent
///   session ID (what the agent's conversation tools return), or the app's
///   own chat ID.
/// - `apelin://project/<id>` opens a project, by its manifest `projectID` or
///   its folder name, on its most recent conversation.
/// - `apelin://chat?prompt=<text>` opens a new General Chat with `<text>`
///   in the composer and the keyboard up. Nothing is sent: the reader reads
///   it and taps Send. Without `prompt` the composer is empty.
/// - `apelin://` opens the app as it is.
///
/// Anything else with the scheme is `unknown`: the app opens and nothing it
/// shows changes. The format is fixed — the agent writes these links too.
enum ApelinLink: Hashable, Sendable {
    case app
    case conversation(String)
    case project(String)
    /// A new General Chat, its composer holding the text, unsent.
    case chat(prompt: String)
    case unknown

    static let scheme = "apelin"

    /// The longest prompt a link may carry, in UTF-8 bytes.
    static let maximumPromptLength = 32768

    /// The link `url` spells, or nil when it is not an `apelin:` URL.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // `apelin://conversation/x` names the kind as the host; a lenient
        // `apelin:conversation/x` has it as the first path component.
        var components = url.pathComponents.filter { $0 != "/" }
        if let host = url.host, !host.isEmpty {
            components.insert(host, at: 0)
        }
        switch components.count {
        case 0:
            self = .app
        case 1 where components[0].lowercased() == "chat":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let prompt = items.first { $0.name == "prompt" }?.value ?? ""
            self = Self.isPrompt(prompt) ? .chat(prompt: prompt) : .unknown
        case 2:
            let value = components[1]
            switch components[0].lowercased() {
            case "conversation" where Self.isIdentifier(value): self = .conversation(value)
            case "project" where Self.isIdentifier(value): self = .project(value)
            default: self = .unknown
            }
        default:
            self = .unknown
        }
    }

    /// The URL that opens this link.
    var url: URL {
        let path = switch self {
        case .app, .unknown: ""
        case let .conversation(id): "conversation/" + Self.escaped(id)
        case let .project(id): "project/" + Self.escaped(id)
        case let .chat(prompt) where prompt.isEmpty: "chat"
        case let .chat(prompt): "chat?prompt=" + Self.escapedQueryValue(prompt)
        }
        // Every part is escaped above, so the string always parses.
        return URL(string: Self.scheme + "://" + path) ?? URL(fileURLWithPath: "/")
    }

    /// A session ID, a chat ID, a project ID or a folder name: one path
    /// component, short, with no control character (a NUL among them).
    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0 == "/" }
    }

    /// Text for the composer: bounded, and no control character but a line
    /// break or a tab.
    private static func isPrompt(_ value: String) -> Bool {
        value.utf8.count <= maximumPromptLength
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0)
            }
    }

    private static func escapedQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func escaped(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
