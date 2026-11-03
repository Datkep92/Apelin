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
enum RateLimitRetryStep: Equatable {
    /// Send the reader's message again, with the next model offered.
    case send
    /// The run the error belongs to is still going: the next model goes
    /// once it ends, since a session takes a new model between runs only.
    case wait
    /// Nothing is left to send: the conversation keeps the error, and the
    /// reader decides what comes next.
    case leaveIt
}

enum RateLimitRetryPolicy {
    /// How many times one message goes again on its own, before the reader
    /// is the one to ask (`Retry` in the model bar).
    static let maximumRetries = 3

    /// `hasMessage` is a message to send again: text, files, or both.
    /// `readerAsked` is the reader's own Retry, which one message's budget
    /// does not limit: they asked, and a model is there. A retry with no
    /// message to send, or with no model left, is not one. A run still
    /// going is waited for in either case: the host applies a prompt's
    /// model to the run it starts, and one that joins a run under way keeps
    /// the model that run began with.
    static func step(
        attempts: Int,
        candidatesLeft: Int,
        hasMessage: Bool,
        isWorking: Bool,
        readerAsked: Bool = false,
    ) -> RateLimitRetryStep {
        guard hasMessage, candidatesLeft > 0 else { return .leaveIt }
        guard readerAsked || attempts < maximumRetries else { return .leaveIt }
        return isWorking ? .wait : .send
    }
}
