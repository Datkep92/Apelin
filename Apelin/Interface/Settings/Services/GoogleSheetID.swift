import Foundation

/// A spreadsheet is stored as an ID, but people paste a whole link. Accept
/// both so configuring a Sheet never needs a copy of just the ID by hand.
enum GoogleSheetID {
    static func parse(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, host.contains("docs.google.com") else {
            return trimmed
        }
        let path = url.path
        guard let start = path.range(of: "/d/") else { return trimmed }
        let rest = path[start.upperBound...]
        return String(rest.split(separator: "/").first ?? Substring(trimmed))
    }
}
