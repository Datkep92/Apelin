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

/// A failure of another kind is not a spent allowance.
require(!RateLimitSignal.matches(""), "Nothing said is not one")
require(!RateLimitSignal.matches("Invalid API key"), "A wrong key is not a spent allowance")
require(!RateLimitSignal.matches("The context is too long for this model"), "An over-long context is not one")
require(!RateLimitSignal.matches("Connection reset by peer"), "A dropped connection is not one")
require(!RateLimitSignal.matches("Error 1429 while reading the response"), "Four digits are not the status")
require(!RateLimitSignal.matches("Request failed: 4290 tokens"), "The status has to stand alone")

// MARK: - What counts as a refused key

/// The providers' and the relays' own words, passed through by the host.
require(CredentialSignal.matches("401 Unauthorized"), "The status is one")
require(CredentialSignal.matches("Incorrect API key provided: sk-abc"), "OpenAI's wording is one")
require(CredentialSignal.matches("invalid_api_key"), "A camel-cased name is one")
require(CredentialSignal.matches("authentication_error: invalid x-api-key"), "Anthropic's wording is one")
require(CredentialSignal.matches("API key not valid. Please pass a valid API key."), "Google's wording is one")
require(CredentialSignal.matches("Unauthorized: missing API key"), "A missing key is one")
require(CredentialSignal.matches("The access token expired"), "An expired token is one")
require(CredentialSignal.matches("Invalid credentials"), "Refused credentials are one")

/// A failure of another kind never moves a conversation to another key.
require(!CredentialSignal.matches(""), "Nothing said is not one")
require(!CredentialSignal.matches("429 Too Many Requests"), "A spent allowance is not a wrong key")
require(!CredentialSignal.matches("The context is too long for this model"), "An over-long context is not one")
require(!CredentialSignal.matches("Invalid model: gpt-5"), "An unknown model is not a wrong key")
require(!CredentialSignal.matches("Connection reset by peer"), "A dropped connection is not one")
require(!CredentialSignal.matches("Failed after 4010 retries"), "The status has to stand alone")

// MARK: - What the retry answers

require(ModelRetrySignal.matches("429 Too Many Requests"), "A spent allowance is one")
require(ModelRetrySignal.matches("Invalid API key"), "A refused key is one")
require(!ModelRetrySignal.matches("The context is too long for this model"), "Nothing else is one")
require(!ModelRetrySignal.matches(""), "And nothing said is not one")

// MARK: - What is left to do

require(
    ModelRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: true, isWorking: false) == .send,
    "A model left and a message to send is a retry",
)
require(
    ModelRetryPolicy.step(attempts: 2, candidatesLeft: 1, hasMessage: true, isWorking: false) == .send,
    "The last automatic try is still a retry",
)
require(
    ModelRetryPolicy.step(
        attempts: ModelRetryPolicy.maximumRetries,
        candidatesLeft: 9,
        hasMessage: true,
        isWorking: false,
    ) == .leaveIt,
    "Automatic tries stop at the budget, a model left or not",
)
require(
    ModelRetryPolicy.step(
        attempts: ModelRetryPolicy.maximumRetries,
        candidatesLeft: 9,
        hasMessage: true,
        isWorking: false,
        readerAsked: true,
    ) == .send,
    "The reader's own Retry is not bound by the budget",
)
require(
    ModelRetryPolicy.step(attempts: 0, candidatesLeft: 0, hasMessage: true, isWorking: false) == .leaveIt,
    "With no model left there is nothing to retry",
)
require(
    ModelRetryPolicy.step(
        attempts: 0,
        candidatesLeft: 0,
        hasMessage: true,
        isWorking: false,
        readerAsked: true,
    ) == .leaveIt,
    "The reader's Retry cannot invent a model",
)
require(
    ModelRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: false, isWorking: false) == .leaveIt,
    "With no message to send again there is nothing to retry",
)
require(
    ModelRetryPolicy.step(attempts: 0, candidatesLeft: 3, hasMessage: true, isWorking: true) == .wait,
    "A run still going is waited for: a prompt that joins it keeps its model",
)
require(
    ModelRetryPolicy.step(
        attempts: 0,
        candidatesLeft: 3,
        hasMessage: true,
        isWorking: true,
        readerAsked: true,
    ) == .wait,
    "The reader's Retry waits for the run too",
)
require(
    ModelRetryPolicy.step(
        attempts: ModelRetryPolicy.maximumRetries,
        candidatesLeft: 3,
        hasMessage: true,
        isWorking: true,
    ) == .leaveIt,
    "A spent budget stops the retry whether a run goes or not",
)

print("ok: what the retry answers (a spent allowance, a refused key, every other failure, the tries left, the run still going, the reader's own Retry)")
