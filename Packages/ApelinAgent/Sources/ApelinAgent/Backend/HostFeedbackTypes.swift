import Foundation

// MARK: - feedback

/// An issue apelin_feedback_send files on Apelin's own repository: the title
/// and body its card showed, nothing else. The repository is the host's
/// constant, and the footer apelin-environment's.
public struct FeedbackToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var title: String
    public var body: String
    public init(context: HostCallContext, title: String, body: String) {
        self.context = context
        self.title = title
        self.body = body
    }
}

public struct FeedbackToolResponse: Sendable, Hashable, Codable {
    public var repository: String
    /// The issue's number there.
    public var issue: Int
    /// Its page on GitHub, which the user is given.
    public var url: String
    public init(repository: String, issue: Int, url: String) {
        self.repository = repository
        self.issue = issue
        self.url = url
    }
}

/// A refusal in words the model can act on and pass on to the user.
public struct FeedbackToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
