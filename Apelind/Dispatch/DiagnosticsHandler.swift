import ApelinProtocol

/// Load confirmation and UI verification, served by apelin-diagnostics.
/// A load check is a task the host owns, so the respring it may trigger —
/// which takes the app down, not the host — cannot lose its answer.
enum DiagnosticsHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .confirmLoaded:
            await host.startTask(request, kind: .confirmLoaded, role: .diagnostics)
        case .confirmLoadedAttach:
            await host.attach(request, ConfirmLoadedAttachRequest.self)
        case .captureScreen, .readUITree:
            await host.forward(request, to: .diagnostics)
        case .uiAction:
            await forwardAction(request, host: host)
        default:
            request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not a diagnostics operation",
            ))
        }
    }

    /// An agent's action never reaches Apelin itself (AgentUIActionRules).
    private static func forwardAction(_ request: HostRequest, host: SessionHost) async -> HostReply {
        var scoped = request
        do {
            scoped.request = try AgentUIActionRules.scoped(request.request, caller: request.caller)
        } catch {
            return request.fail(error)
        }
        return await host.forward(scoped, to: .diagnostics)
    }
}
