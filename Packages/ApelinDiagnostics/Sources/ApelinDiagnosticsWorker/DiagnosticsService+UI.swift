import ApelinCore
import ApelinDiagnostics
import ApelinProtocol

extension DiagnosticsService {
    // MARK: UI

    /// The foreground is settled once, inside `blocking` (the wait sleeps),
    /// and that read both binds the target and stands for the read's own wait.
    func readUITree(_ tree: ApelinProtocol.ReadUITreeRequest) async throws -> ApelinProtocol.ReadUITreeResponse {
        let read = try await blocking {
            let front = try requireTarget(tree.targetID)
            return try mapped { try diagnostics.uiTree(UITreeRequest(), settled: front) }
        }
        return try ApelinProtocol.ReadUITreeResponse(tree: JSONValue(encoding: read))
    }

    /// A `type` answers what it left in the fields, read back from the tree.
    func uiAction(_ action: ApelinProtocol.UIActionRequest) async throws -> ApelinProtocol.UIActionResponse {
        let mappedAction = try Self.action(action.action)
        let typed = try await blocking {
            let front = try requireTarget(action.targetID)
            return try mapped { try diagnostics.perform(mappedAction, settled: front) }
        }
        return ApelinProtocol.UIActionResponse(typedTextMatches: typed?.matches, fieldValues: typed?.fieldValues)
    }

    /// An action is bound to the verified foreground app when a target is
    /// named; without one it goes to whatever is in front. Answers the
    /// settled read it checked, nil without a target. It waits: call it
    /// inside `blocking`.
    @discardableResult
    func requireTarget(_ targetID: String?) throws -> ForegroundApp? {
        guard let targetID else { return nil }
        // Read once the app switch that brings it there, if any, is over.
        let front = diagnostics.settledForegroundApp(expecting: targetID)
        guard front.verified, front.bundleIdentifier == targetID else {
            let seen = front.bundleIdentifier.isEmpty ? "unknown" : front.bundleIdentifier
            throw ApelinError(.conflict, "\(targetID) is not the verified foreground app after \(Int(diagnostics.settleTimeout)) s (\(seen))")
        }
        return front
    }

    static func action(_ action: ApelinProtocol.UIAction) throws -> ApelinDiagnosticsCore.UIAction {
        switch action {
        case let .tap(x, y):
            return .tap(UIPoint(x: x, y: y))
        case let .tapElement(text, identifier):
            return .tapElement(UIElementSelector(
                text: text,
                identifier: identifier,
                match: identifier == nil ? .exact : .contains,
            ))
        case let .type(text):
            return .type(text: text, delayMilliseconds: ApelinDiagnosticsCore.UIAction.defaultTypeDelayMilliseconds)
        case let .swipe(fromX, fromY, toX, toY, durationMilliseconds):
            return .swipe(
                from: UIPoint(x: fromX, y: fromY),
                to: UIPoint(x: toX, y: toY),
                seconds: Double(durationMilliseconds) / 1000,
            )
        case let .press(button):
            throw ApelinError(.unavailable, "Pressing the \(button) button is not supported.")
        }
    }
}
