import Foundation

func require(_ condition: Bool, _ message: String, line: Int = #line) {
    guard condition else { fatalError("Line \(line): \(message)") }
}

// MARK: - What counts as a spent allowance

/// The host's own wording (`AgentSession`).
require(
    RateLimitSignal.matches("Rate limit / quota reached for this model"),
    "The host's own sentence is one",
)
/// A provider's words, passed through by an older host.
require(RateLimitSignal.matches("429 Too Many Requests"), "The status is one")
require(RateLimitSignal.matches("You have hit your usage limit"), "A usage limit is one")
require(RateLimitSignal.matches("resource_exhausted: quota exceeded"), "An exhausted resource is one")
require(RateLimitSignal.matches("RateLimitError: too many requests"), "A camel-cased name is one")
require(RateLimitSignal.matches("Please retry-after 20 seconds"), "A retry-after hint is one")
require(RateLimitSignal.matches("Quota exceeded for quota metric"), "A capitalised quota is one")

/// Anything else is the model's own failure, and is never retried on
/// another model.
require(!RateLimitSignal.matches(""), "Nothing said is not one")
require(!RateLimitSignal.matches("Invalid API key"), "A wrong key is not one")
require(!RateLimitSignal.matches("The context is too long for this model"), "An over-long context is not one")
require(!RateLimitSignal.matches("Connection reset by peer"), "A dropped connection is not one")
require(!RateLimitSignal.matches("Error 1429 while reading the response"), "Four digits are not the status")
require(!RateLimitSignal.matches("Request failed: 4290 tokens"), "The status has to stand alone")

// MARK: - What is left to do

require(
    RateLimitRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: true, isWorking: false) == .send,
    "A model left and a message to send is a retry",
)
require(
    RateLimitRetryPolicy.step(attempts: 2, candidatesLeft: 1, hasMessage: true, isWorking: false) == .send,
    "The last automatic try is still a retry",
)
require(
    RateLimitRetryPolicy.step(
        attempts: RateLimitRetryPolicy.maximumRetries,
        candidatesLeft: 9,
        hasMessage: true,
        isWorking: false,
    ) == .leaveIt,
    "Automatic tries stop at the budget, a model left or not",
)
require(
    RateLimitRetryPolicy.step(
        attempts: RateLimitRetryPolicy.maximumRetries,
        candidatesLeft: 9,
        hasMessage: true,
        isWorking: false,
        readerAsked: true,
    ) == .send,
    "The reader's own Retry is not bound by the budget",
)
require(
    RateLimitRetryPolicy.step(attempts: 0, candidatesLeft: 0, hasMessage: true, isWorking: false) == .leaveIt,
    "With no model left there is nothing to retry",
)
require(
    RateLimitRetryPolicy.step(
        attempts: 0,
        candidatesLeft: 0,
        hasMessage: true,
        isWorking: false,
        readerAsked: true,
    ) == .leaveIt,
    "The reader's Retry cannot invent a model",
)
require(
    RateLimitRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: false, isWorking: false) == .leaveIt,
    "With no message to send again there is nothing to retry",
)
require(
    RateLimitRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: true, isWorking: true) == .wait,
    "A run still going is waited for: a prompt that joins it keeps its model",
)
require(
    RateLimitRetryPolicy.step(
        attempts: 0,
        candidatesLeft: 3,
        hasMessage: true,
        isWorking: true,
        readerAsked: true,
    ) == .wait,
    "The reader's Retry waits for the run too",
)
require(
    RateLimitRetryPolicy.step(
        attempts: RateLimitRetryPolicy.maximumRetries,
        candidatesLeft: 3,
        hasMessage: true,
        isWorking: true,
    ) == .leaveIt,
    "A spent budget stops the retry whether a run goes or not",
)

print("ok: a spent allowance (429, rate limit, quota, every other failure, the tries left, the run still going, the reader's own Retry)")
