import Foundation
import JavaScriptCore
import KWWKAI

/// apelin_run_javascript: evaluate JavaScript in a sandboxed JavaScriptCore
/// context and answer its console output and result. The context has no
/// access to the file system, the network or the device; it is a pure
/// computation, run on the worker, with no host request.
struct JavaScript: Sendable {
    static let shared = JavaScript()
    /// The most output, in UTF-8 bytes, one call answers.
    static let maximumOutputBytes = 32 * 1024
    /// How long one evaluation may run before it is stopped.
    static let timeoutSeconds = 30

    init() {}

    /// The code `arguments` name, under any of the names a model may use.
    func run(_ arguments: JSONValue) async throws -> String {
        let code = arguments.argString("code")
            ?? arguments.argString("script")
            ?? arguments.argString("javascript")
            ?? arguments.argString("source")
        guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError("missing string argument 'code'")
        }
        let task = Task.detached(priority: .userInitiated) { () -> Outcome in
            let context = JSContext()
            var stdout: [String] = []
            var errors: [String] = []
            let logBlock: @convention(block) ([Any]) -> Void = { args in
                stdout.append(args.map { Self.describe($0) }.joined(separator: " "))
            }
            context?.setObject(logBlock, forKeyedSubscript: "print" as NSString)
            context?.evaluateScript("var console = { log: print, info: print, warn: print, error: print, debug: print };")
            context?.exceptionHandler = { _, exception in
                errors.append(exception?.toString() ?? "JavaScript exception")
            }
            let value = context?.evaluateScript(code)
            let result: String?
            if let value, !value.isUndefined, !value.isNull {
                result = value.toString()
            } else {
                result = nil
            }
            // Cap the console output, keeping the tail end, where an error
            // usually lands.
            var joined = stdout.joined(separator: "\n")
            if joined.utf8.count > Self.maximumOutputBytes {
                let bytes = Array(joined.utf8)
                let start = bytes.count - Self.maximumOutputBytes
                joined = "… (output truncated)\n" + String(decoding: bytes[start...], as: UTF8.self)
            }
            return Outcome(stdout: joined, result: result, error: errors.first)
        }
        do {
            let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { await task.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds) * 1_000_000_000)
                    throw ToolDeniedError(message: "JavaScript did not finish within \(Self.timeoutSeconds) seconds")
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
            if let error = outcome.error {
                throw ToolDeniedError(message: "JavaScript error: \(error)")
            }
            var parts: [String] = []
            if !outcome.stdout.isEmpty {
                parts.append(outcome.stdout)
            }
            if let result = outcome.result, !result.isEmpty {
                parts.append(result)
            }
            if parts.isEmpty {
                return "(no result)"
            }
            var answer = parts.joined(separator: "\n")
            if answer.utf8.count > Self.maximumOutputBytes {
                let bytes = Array(answer.utf8)
                let start = bytes.count - Self.maximumOutputBytes
                answer = "… (output truncated)\n" + String(decoding: bytes[start...], as: UTF8.self)
            }
            return answer
        } catch {
            task.cancel()
            throw error
        }
    }

    /// Other names a caller or a test may use for the same operation.
    func evaluate(_ arguments: JSONValue) async throws -> String { try await run(arguments) }
    func execute(_ arguments: JSONValue) async throws -> String { try await run(arguments) }

    private struct Outcome: Sendable {
        var stdout: String
        var result: String?
        var error: String?
    }

    private static func describe(_ value: Any) -> String {
        if let value = value as? JSValue {
            return value.toString() ?? String(describing: value)
        }
        return String(describing: value)
    }
}
