import Foundation

/// A model that answered with a spent allowance: HTTP 429, a rate limit, a
/// quota. The host words one as a sentence of its own
/// (`AgentSession`, "Rate limit / quota reached for this model"); an older
/// host passes the provider's own text through, which is where the status
/// numbers and the other wordings come from. Another failure — a wrong key,
/// a context that is too long — is not one, and is never retried.
enum RateLimitSignal {
    /// Wordings that name a spent allowance.
    private static let wordings = [
        "rate limit", "rate-limit", "rate_limit", "ratelimit",
        "too many requests", "resource exhausted", "resource_exhausted",
        "quota", "usage limit", "retry-after",
    ]

    static func matches(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !text.isEmpty else { return false }
        if wordings.contains(where: { text.contains($0) }) { return true }
        return namesStatus429(text)
    }

    /// `429` as a status, not as four digits inside a longer number: a
    /// token count of `1429` is not a spent allowance.
    private static func namesStatus429(_ text: String) -> Bool {
        var index = text.startIndex
        while let found = text[index...].range(of: "429") {
            if !isDigit(text[..<found.lowerBound].last), !isDigit(text[found.upperBound...].first) {
                return true
            }
            index = found.upperBound
        }
        return false
    }

    private static func isDigit(_ character: Character?) -> Bool {
        character?.isNumber == true
    }
}

/// What a spent allowance leaves to do.
enum RateLimitRetryDecision: Equatable {
    /// Send the reader's message again, with the next model offered.
    case sendNextModel
    /// Nothing is left to send: the conversation keeps the error, and the
    /// reader decides what comes next.
    case leaveIt
}

enum RateLimitRetryPolicy {
    /// How many times one message goes again on its own, before the reader
    /// is the one to ask (`Retry` in the model bar).
    static let maximumRetries = 3

    /// `readerAsked` is the reader's own Retry, which one message's budget
    /// does not limit: they asked, and a model is there. A retry with no
    /// message to send, or with no model left, is not one.
    static func decision(
        attempts: Int,
        candidatesLeft: Int,
        hasText: Bool,
        readerAsked: Bool = false,
    ) -> RateLimitRetryDecision {
        guard hasText, candidatesLeft > 0 else { return .leaveIt }
        return readerAsked || attempts < maximumRetries ? .sendNextModel : .leaveIt
    }
}
