import Foundation

/// A status number inside a message, as a whole number: the `429` of
/// `Request failed: 4290 tokens` is a token count, not the status.
private enum StatusNumber {
    static func isNamed(_ code: String, in message: String) -> Bool {
        var index = message.startIndex
        while let found = message[index...].range(of: code) {
            if !isDigit(message[..<found.lowerBound].last), !isDigit(message[found.upperBound...].first) {
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

/// A model that answered with a spent allowance: HTTP 429, a rate limit, a
/// quota. The host words one as a sentence of its own
/// (`AgentSession`, "Rate limit / quota reached for this model"); an older
/// host passes the provider's own text through, which is where the status
/// numbers and the other wordings come from.
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
        return StatusNumber.isNamed("429", in: text)
    }
}

/// A key the endpoint refused: HTTP 401, an invalid, a missing or an expired
/// key or token. The host passes the provider's own words through
/// (`AgentSession`), so these are the providers' and the relays': OpenAI's
/// "Incorrect API key provided", Anthropic's "authentication_error", "Invalid
/// API key" from a gateway. A failure of another kind — a context that is too
/// long, a model that does not exist, a connection that dropped — is not one,
/// and never moves a conversation to another key.
enum CredentialSignal {
    /// Wordings that name a refused key.
    private static let wordings = [
        "invalid api key", "invalid_api_key", "incorrect api key",
        "api key not valid", "no api key", "missing api key", "api key is required",
        "invalid x-api-key", "missing x-api-key",
        "authentication_error", "authentication failed", "invalid credentials",
        "unauthorized", "not authorized", "invalid token", "token expired", "expired token",
    ]

    static func matches(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !text.isEmpty else { return false }
        if wordings.contains(where: { text.contains($0) }) { return true }
        return StatusNumber.isNamed("401", in: text)
    }
}

/// What another model, or another key, can answer: a spent allowance
/// (`RateLimitSignal`) or a key the endpoint refused (`CredentialSignal`),
/// and nothing else. Either one sends the reader's message again on the next
/// candidate of `ModelCandidates.fallbackList`, which puts the same model on
/// another configuration of the provider — another key — first, so a refused
/// key moves the conversation to one that answers.
enum ModelRetrySignal {
    static func matches(_ message: String) -> Bool {
        RateLimitSignal.matches(message) || CredentialSignal.matches(message)
    }
}

/// What a failure the retry answers leaves to do.
enum ModelRetryStep: Equatable {
    /// Send the reader's message again, with the next model offered.
    case send
    /// The run the error belongs to is still going: the next model goes
    /// once it ends, since a session takes a new model between runs only.
    case wait
    /// Nothing is left to send: the conversation keeps the error, and the
    /// reader decides what comes next.
    case leaveIt
}

enum ModelRetryPolicy {
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
    ) -> ModelRetryStep {
        guard hasMessage, candidatesLeft > 0 else { return .leaveIt }
        guard readerAsked || attempts < maximumRetries else { return .leaveIt }
        return isWorking ? .wait : .send
    }
}
