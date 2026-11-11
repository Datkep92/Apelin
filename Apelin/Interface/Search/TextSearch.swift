import Foundation

/// How the reader's words are looked for in a title, in what was said in a
/// conversation and in what a file holds: one rule for the sidebar's search
/// and for the Files screen's, so both find the same things.
///
/// Case, accents and `đ` are set aside, so `buoi` finds `Buổi` and `duong`
/// finds `Đường` — `String.CompareOptions.diacriticInsensitive` folds every
/// accent but that one letter, so it is folded here before the comparison.
/// The words are never read as a pattern: `a.b` looks for `a.b`, not for `axb`.
enum TextSearch {
    /// What both searches compare with: the reader's own field, and the
    /// conversation titles the sidebar has always filtered this way.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// `text` with `đ` written as `d`, one character for one, so a position
    /// in what this answers is the same position in what it was given.
    static func folding(_ text: String) -> String {
        text
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
    }

    /// Whether `text` holds `query`.
    static func holds(_ text: String?, _ query: String) -> Bool {
        guard let text, !query.isEmpty else { return false }
        return folding(text).range(of: folding(query), options: options) != nil
    }

    /// The line of `text` holding `query`, with at most `context` characters
    /// either side and at most `limit` long, marked with an ellipsis where it
    /// was cut: what a row shows to say why it is in the list. The line keeps
    /// its own spelling — the fold is only what the match is found on.
    ///
    /// Nil when no line holds `query`. The first line that does is the one
    /// answered, so a long history is read no further than its match.
    static func line(
        of text: String,
        holding query: String,
        context: Int = 28,
        limit: Int = 140,
    ) -> String? {
        guard !query.isEmpty else { return nil }
        let needle = folding(query)
        for line in text.split(whereSeparator: \.isNewline) {
            let lineText = String(line)
            let folded = folding(lineText)
            // The fold writes one character for one, so where the match sits
            // in `folded` is where it sits in `lineText`.
            guard folded.count == lineText.count,
                  let found = folded.range(of: needle, options: options)
            else { continue }
            let lower = lineText.index(
                lineText.startIndex,
                offsetBy: folded.distance(from: folded.startIndex, to: found.lowerBound),
            )
            let upper = lineText.index(
                lineText.startIndex,
                offsetBy: folded.distance(from: folded.startIndex, to: found.upperBound),
            )
            let start = lineText.index(lower, offsetBy: -context, limitedBy: lineText.startIndex)
                ?? lineText.startIndex
            let end = lineText.index(upper, offsetBy: context, limitedBy: lineText.endIndex)
                ?? lineText.endIndex
            var snippet = String(lineText[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.isEmpty { return String(lineText[lower..<upper]) }
            if start > lineText.startIndex { snippet = "..." + snippet }
            if end < lineText.endIndex { snippet += "..." }
            if snippet.count > limit { snippet = String(snippet.prefix(limit)) + "..." }
            return snippet
        }
        return nil
    }
}