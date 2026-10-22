import Foundation

// MARK: - run_code

/// How `run_code` was classified, structurally (never by command prefix).
public enum RunCodeInvocation: Sendable, Hashable, Codable {
    /// A plain argv: executable name (no path) and arguments.
    case argv([String])
    /// Shell text that did not reduce to a plain argv: pipes, redirection,
    /// substitution, several commands, or anything unparsed.
    case shell(String)
    /// A script handed to an interpreter (`sh`, `bash`, `python3`, …).
    case script(interpreter: String, source: String)
}

public struct RunCodeRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var invocation: RunCodeInvocation
    /// Relative to the project root; the host re-canonicalises it.
    public var workingDirectory: String
    public var timeoutSeconds: Int

    public init(
        context: HostCallContext,
        invocation: RunCodeInvocation,
        workingDirectory: String,
        timeoutSeconds: Int,
    ) {
        self.context = context
        self.invocation = invocation
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }
}

/// The host did not run a call the agent sent as a preset: its own rule
/// (Apelind's `AgentRunCode.preset`) does not count it as one. The call
/// needs the user's approval instead, which the runner asks for.
public struct HostRefusedPresetError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}

public struct RunCodeResponse: Sendable, Hashable, Codable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var truncated: Bool
    public var durationMilliseconds: Int

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool = false,
        durationMilliseconds: Int = 0,
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.durationMilliseconds = durationMilliseconds
    }
}
