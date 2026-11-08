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
    /// Wordings that name a spent allowance. Keep these words in sync with the
    /// ones `AgentSession` uses to word the same failure (`Packages/ApelinAgent/...`).
    private static let wordings = [
        "rate limit", "rate-limit", "rate_limit", "ratelimit",
        "too many requests", "resource exhausted", "resource_exhausted",
        "quota", "usage limit", "retry-after",
        "allowance", "free usage", "free tier", "free allowance", "free plan",
        "exhausted", "depleted", "spent", "used up", "insufficient", "budget",
        "token harbor", "tokenharbor",
    ]

    static func matches(_ message: String) -> Bool {
        let text = message.lowercased()
        guard !text.isEmpty else { return false }
        if wordings.contains(where: { text.contains($0) }) { return true }
        return StatusNumber.isNamed("429", in: text)
            || StatusNumber.isNamed("402", in: text)
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

/// Why another key or another model can answer, as far as the failure says so.
/// The wording is the only thing an error event carries
/// (`AgentWorker`: `("error", ["message": …])`), so the kind is read out of
/// it: what the provider said, or the host's own sentence for it.
enum ModelFailureKind: String, Codable, Sendable {
    /// The allowance is spent: a quota, a rate limit, HTTP 429. Another key on
    /// the same address answers, and this one is worth trying again later.
    case spentAllowance
    /// The key was refused: HTTP 401, an invalid, a missing or an expired key.
    /// Another key answers; this one never will, and waits longest.
    case refusedKey
    /// The provider failed on its side: HTTP 5xx, an overloaded or an
    /// unavailable upstream. Another key or a moment later answers.
    case serverError
    /// The request never got an answer: a connection that dropped, a host
    /// that does not resolve, a timeout. Another key answers nothing — the
    /// request may still have been served, so the automatic retry leaves it
    /// to the reader.
    case unreachable
}

/// A failure another model, or another key, can answer: a spent allowance
/// (`RateLimitSignal`), a key the endpoint refused (`CredentialSignal`), a
/// server that failed on its side, or a request that never arrived. Either
/// one sends the reader's message again on the next candidate of
/// `ModelCandidates.fallbackList`, which puts the same model on another key of
/// the same Base URL first, so a refused or a spent key moves the conversation
/// to one that answers.
enum ModelRetrySignal {
    /// Wordings that name a failure on the provider's side.
    private static let serverWordings = [
        "internal server error", "bad gateway", "service unavailable",
        "gateway timeout", "server error", "upstream error", "overloaded",
        "provider returned an error",
    ]

    /// Wordings that name a request that never arrived.
    private static let transportWordings = [
        "connection reset", "connection refused", "connection closed",
        "network error", "network is unreachable", "timed out", "timeout",
        "could not connect", "cannot connect", "no route to host",
        "host is down", "socket", "tls", "ssl error", "eof",
    ]

    /// The kind of failure `message` names, or nil when it names something no
    /// other candidate answers — an over-long context, a model that does not
    /// exist, a request the provider rejected.
    static func kind(of message: String) -> ModelFailureKind? {
        if RateLimitSignal.matches(message) { return .spentAllowance }
        if CredentialSignal.matches(message) { return .refusedKey }
        let text = message.lowercased()
        guard !text.isEmpty else { return nil }
        if serverWordings.contains(where: { text.contains($0) }) { return .serverError }
        if StatusNumber.isNamed("500", in: text) || StatusNumber.isNamed("502", in: text)
            || StatusNumber.isNamed("503", in: text) || StatusNumber.isNamed("504", in: text)
        {
            return .serverError
        }
        if transportWordings.contains(where: { text.contains($0) }) { return .unreachable }
        return nil
    }

    static func matches(_ message: String) -> Bool {
        kind(of: message) != nil
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

    /// Whether the kind of failure leaves an automatic retry to run at all.
    /// Everything but a request that never arrived does: a spent allowance, a
    /// refused key and a server that failed are all worth another candidate,
    /// while a dropped connection cannot say whether the model answered
    /// (`ModelFailureKind.unreachable`), so that one waits for the reader's
    /// own Retry.
    static func automatic(_ kind: ModelFailureKind) -> Bool {
        kind != .unreachable
    }

    /// How long the candidate that failed is left alone, from the kind of
    /// failure: a key the provider refused needs a hand and a new key, so it
    /// waits longest; a spent allowance comes back; a server that failed may
    /// answer a moment later. nil leaves no wait.
    static func cooldown(for kind: ModelFailureKind) -> TimeInterval? {
        switch kind {
        case .spentAllowance: 45
        case .refusedKey: 300
        case .serverError: 20
        case .unreachable: nil
        }
    }

    /// `hasMessage` is a message to send again: text, files, or both.
    /// `readerAsked` is the reader's own Retry, which one message's budget
    /// does not limit: they asked, and a model is there. A retry with no
    /// message to send, or with no model left, is not one. A run still
    /// going is waited for in either case: the host applies a prompt's
    /// model to the run it starts, and one that joins a run under way keeps
    /// the model that run began with. `automatic` is false for a failure a
    /// candidate cannot answer (`ModelRetryPolicy.automatic(_:)`): the list
    /// stays, and the reader's own Retry is what spends it.
    static func step(
        attempts: Int,
        candidatesLeft: Int,
        hasMessage: Bool,
        isWorking: Bool,
        readerAsked: Bool = false,
        automatic: Bool = true,
    ) -> ModelRetryStep {
        guard hasMessage, candidatesLeft > 0 else { return .leaveIt }
        guard readerAsked || (automatic && attempts < maximumRetries) else { return .leaveIt }
        return isWorking ? .wait : .send
    }
}
